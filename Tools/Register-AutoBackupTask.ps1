#requires -Version 5.1
<#
====================================================================
 Register-AutoBackupTask.ps1
 AutoDriveBackup.ps1 을 작업 스케줄러에 등록한다.

 [실행 방식]
   - 최고 권한(Highest) + S4U 로그온 유형 -> 세션 0 에서 실행되므로
     콘솔 창이 전혀 뜨지 않는다. (-WindowStyle Hidden 은 창이 깜빡일 수 있음)
   - -Mode BackupNow (상주 감시가 아니라 1회 실행). 매 5분 반복이 감시를 대신한다.
     상주 프로세스가 없으므로 죽어도 다음 주기에 스스로 복구된다.

 [트리거]
   - 컴퓨터 시작 시
   - 로그온 시
   - 워크스테이션 잠금 해제 시
   - 위 각각에 대해 5분 간격 무기한 반복

 [사용법]  관리자 권한 PowerShell 에서
   등록:     .\Register-AutoBackupTask.ps1
   즉시실행: Start-ScheduledTask -TaskName 'AutoDriveBackup'
   상태:     Get-ScheduledTask -TaskName 'AutoDriveBackup' | Get-ScheduledTaskInfo
   해제:     Unregister-ScheduledTask -TaskName 'AutoDriveBackup' -Confirm:$false

 ※ 이 파일도 UTF-8 with BOM 으로 저장할 것.
====================================================================
#>
param(
    [string]$TaskName        = 'AutoDriveBackup',
    [string]$ScriptPath      = (Join-Path $PSScriptRoot 'AutoDriveBackup.ps1'),
    [string]$BackupRoot      = 'C:\DriveBackup',
    [int]$IntervalMinutes    = 5,
    [string[]]$ExcludeDrives = @(),
    [switch]$Mirror,
    [switch]$UseInteractive   # S4U 등록이 실패할 때만 사용 (로그온 중에만 동작)
)

$ErrorActionPreference = 'Stop'

# ---- 사전 검사 -----------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "관리자 권한 PowerShell 에서 실행하세요." -ForegroundColor Red
    exit 1
}

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction SilentlyContinue).Path
if (-not $resolved) {
    Write-Host "AutoDriveBackup.ps1 을 찾을 수 없습니다. -ScriptPath 로 지정하세요." -ForegroundColor Red
    exit 1
}
$ScriptPath = $resolved

# 등록 전에 구문 검사 - 깨진 스크립트를 스케줄러에 올리면 5분마다 조용히 실패만 반복한다
$perr = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$perr) | Out-Null
if ($perr) {
    Write-Host "스크립트에 구문 오류가 있어 등록을 중단합니다:" -ForegroundColor Red
    $perr | ForEach-Object { Write-Host ("  {0}행: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    exit 1
}

$head = [System.IO.File]::ReadAllBytes($ScriptPath)
if ($head.Length -lt 3 -or -not ($head[0] -eq 239 -and $head[1] -eq 187 -and $head[2] -eq 191)) {
    Write-Host "경고: UTF-8 BOM 이 없습니다. PowerShell 5.1 이 CP949 로 잘못 읽어 한글이 깨질 수 있습니다." -ForegroundColor Yellow
}

# ---- Action --------------------------------------------------------
$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" " +
           "-Mode BackupNow -BackupRoot `"$BackupRoot`""
if ($ExcludeDrives.Count) { $argLine += " -ExcludeDrives $($ExcludeDrives -join ',')" }
if ($Mirror)              { $argLine += " -Mirror" }

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument $argLine -WorkingDirectory (Split-Path $ScriptPath)

# ---- 반복 설정(무기한) 및 트리거 생성 ---------------------------------------------
$userId = "$env:USERDOMAIN\$env:USERNAME"
$triggers = New-Object System.Collections.Generic.List[object]

# 임시 트리거를 생성해 '무기한 반복(Duration 없음)'이 적용된 Repetition 객체만 추출
$rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)).Repetition

# 1. 부팅 트리거
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = 'PT2M'
$tBoot.Repetition = $rep
$triggers.Add($tBoot)

# 2. 로그온 트리거
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $userId
$tLogon.Delay = 'PT1M'
$tLogon.Repetition = $rep
$triggers.Add($tLogon)

# 3. 잠금 해제 트리거
try {
    $cls = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $tUnlock = New-CimInstance -CimClass $cls -ClientOnly
    $tUnlock.StateChange = 8  # SessionUnlock
    $tUnlock.UserId      = $userId
    $tUnlock.Enabled     = $true
    $tUnlock.Repetition  = $rep
    $triggers.Add($tUnlock)
} catch {
    Write-Host "잠금 해제 트리거 생성 실패(무시하고 계속): $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- Settings ------------------------------------------------------
# MultipleInstances = IgnoreNew 가 핵심.
# 백업이 5분보다 오래 걸릴 때 프로세스가 겹쳐 쌓이는 것을 막는다.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5) `
    -Priority 7

# ---- Principal -----------------------------------------------------
$principal = if ($UseInteractive) {
    New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
} else {
    New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest
}

# ---- 등록 ----------------------------------------------------------
$desc = "USB/외장 스토리지 자동 Git 백업 ($IntervalMinutes 분 주기)"
try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force -Description $desc | Out-Null
    $mode = if ($UseInteractive) { 'Interactive' } else { 'S4U' }
} catch {
    if ($UseInteractive) { throw }
    Write-Host "S4U 등록 실패 - Interactive 로 재시도: $($_.Exception.Message)" -ForegroundColor Yellow
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force -Description $desc | Out-Null
    $mode = 'Interactive'
    Write-Host "Interactive 등록됨: 로그온 중에만 동작하고 창이 잠깐 보일 수 있습니다." -ForegroundColor Yellow
}

Write-Host "등록 완료: '$TaskName'" -ForegroundColor Green
Write-Host "  로그온유형 : $mode (RunLevel Highest)"
Write-Host "  실행       : powershell.exe $argLine"
Write-Host "  주기       : $IntervalMinutes 분, 무기한"
Write-Host "  트리거     : 컴퓨터 시작 / 로그온 / 잠금 해제"
Write-Host "  중복 실행  : IgnoreNew"
Write-Host ""
Write-Host "시험 실행 : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "실행 결과 : Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "동작 로그 : Get-Content '$BackupRoot\_meta\watcher.log' -Tail 30"
