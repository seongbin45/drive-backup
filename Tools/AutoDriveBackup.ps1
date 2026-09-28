#requires -Version 5.1
<#
====================================================================
 AutoDriveBackup.ps1
 USB / 외장 HDD·SSD 감지 → 백그라운드 자동 백업 → Git 커밋 누적
 + 중단 후 재개(resume) + 메타데이터 대조 검증
--------------------------------------------------------------------
 [폴더 구조]
   C:\DriveBackup\           <- $BackupRoot (기본값)
     O_\                     <- O: 드라이브 백업본 (git repo)
       .git\
       (드라이브 파일들...)
     E_\                     <- E: 드라이브 백업본
     _meta\                  <- 상태/로그/매니페스트 (백업본 밖에 둠)
       O_\
         backup_state.json   <- 재개/상태 정보
         manifest.json       <- 지난 백업 완료 시점의 드라이브 파일 목록
         robocopy_*.log
         verify_*.csv
       watcher.log

 [사용법]
   감시 시작(백그라운드 상주):
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode Watch
   수동 즉시 백업:
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode BackupNow -Letter O
   검증(백업본 vs 현재 드라이브 변경/수정 여부 대조):
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode Verify -Letter O
   검증(전체 SHA-256 해시까지 대조, 느림):
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode Verify -Letter O -DeepHash
   전체 상태 요약:
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode Status
   드라이브 스캔(무엇이 백업 대상이고 왜 제외되는지 확인, 아무것도 건드리지 않음):
     powershell -NoProfile -ExecutionPolicy Bypass -File AutoDriveBackup.ps1 -Mode Scan

   -Letter 를 생략하면 시스템 볼륨을 자동으로 걸러내고 남은 드라이브를 전부 처리한다.

   ※ 이 파일은 반드시 UTF-8 with BOM 으로 저장할 것.
     BOM 이 없으면 PowerShell 5.1 이 CP949 로 잘못 읽어 구문 오류가 난다.

 [옵션]
   -Mirror : 드라이브에서 삭제된 파일을 백업본에서도 삭제(robocopy /MIR).
             삭제 내역은 git 커밋에 기록되므로 과거 버전 복구는 가능.
             기본값은 "삭제 전파 안 함"(안전 우선).
====================================================================
#>
param(
    [ValidateSet('Watch','BackupNow','Verify','Status','Scan')]
    [string]$Mode = 'Watch',
    [string]$Letter,
    [string[]]$ExcludeDrives = @(),          # 수동으로 제외할 드라이브 문자
    [switch]$IncludeSystemVolumes,           # 시스템 볼륨 자동 제외를 끔 (권장하지 않음)
    [switch]$NoSpaceCheck,                   # 최초 백업 시 용량 사전검사를 끔
    [int]$FreeMarginGB = 5,                  # 백업 루트에 남겨둘 여유 공간
    [string]$BackupRoot = 'C:\DriveBackup',
    [switch]$Mirror,
    [switch]$DeepHash,
    [int]$PollSeconds = 5,
    [int]$CooldownSeconds = 90
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 백업 대상에서 제외할 시스템 항목
$ExcludeDirs  = @('.git', 'System Volume Information', '$RECYCLE.BIN', 'FOUND.000', 'Recovery', 'Config.Msi')
$ExcludeFiles = @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'DumpStack.log.tmp', 'desktop.ini')

# 드라이브 "최상위"에서만 제외할 OS 설치 디렉터리
# (하위 경로의 동명 폴더 예: O:\Backup\Program Files 는 보존)
$SystemTopDirs = @('Windows','Program Files','Program Files (x86)','ProgramData',
                   'PerfLogs','Boot','EFI','MSOCache','OneDriveTemp','Documents and Settings')

function Get-DriveSystemDirs([string]$L) {
    $root = "${L}:\"
    # 폴더 이름이 아니라 실제 OS 시그니처 파일로 판정 (사용자가 만든 'Windows' 폴더 오탐 방지)
    $markers = @('Windows\System32\config\SYSTEM','Windows\System32\ntoskrnl.exe','Windows\explorer.exe')
    $isOs = $false
    foreach ($m in $markers) {
        if (Test-Path -LiteralPath (Join-Path $root $m) -PathType Leaf) { $isOs = $true; break }
    }
    $found = @()
    foreach ($d in $SystemTopDirs) {
        if (Test-Path -LiteralPath (Join-Path $root $d) -PathType Container) { $found += $d }
    }
    return [pscustomobject]@{ IsOsVolume = $isOs; TopDirs = $found }
}

$MetaRoot = Join-Path $BackupRoot '_meta'
New-Item -ItemType Directory -Force -Path $MetaRoot | Out-Null
$WatcherLog = Join-Path $MetaRoot 'watcher.log'

function Write-Log([string]$msg, [string]$tag = 'INFO') {
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $tag, $msg
    Add-Content -Path $WatcherLog -Value $line -Encoding UTF8
    if ($Mode -ne 'Watch') { Write-Host $line }
    else { Write-Host $line }
}

# 백업 루트가 있는 드라이브 문자 (예: C) - 이 드라이브는 백업 대상에서 제외
$resolvedRoot = (Resolve-Path -LiteralPath $BackupRoot -ErrorAction SilentlyContinue).Path
if ([string]::IsNullOrWhiteSpace($resolvedRoot)) { $resolvedRoot = $BackupRoot }
$pathRoot = [System.IO.Path]::GetPathRoot($resolvedRoot)
if     ($pathRoot   -match '^([A-Za-z]):') { $RootDriveLetter = $Matches[1].ToUpper() }
elseif ($BackupRoot -match '^([A-Za-z]):') { $RootDriveLetter = $Matches[1].ToUpper() }
else { throw "BackupRoot('$BackupRoot')가 드라이브 문자 경로가 아닙니다. UNC/상대경로는 지원하지 않습니다." }

#--------------------------------------------------------------------
# 시스템 볼륨 판정: 폴더 이름이 아니라 실제 시스템 파일 존재로 판단
# 사용자가 -Letter 로 지정하지 않아도 자동으로 걸러내기 위한 핵심 로직
#--------------------------------------------------------------------
function Test-SystemVolume([string]$L) {
    $root    = "${L}:\"
    $reasons = @()

    # OS 커널/레지스트리 하이브 = Windows 설치 볼륨 (현재 부팅본이든 과거 설치본이든)
    foreach ($m in @('Windows\System32\config\SYSTEM',
                     'Windows\System32\ntoskrnl.exe',
                     'Windows\System32\winload.exe',
                     'Windows\explorer.exe')) {
        if (Test-Path -LiteralPath (Join-Path $root $m) -PathType Leaf) { $reasons += 'Windows 설치 볼륨'; break }
    }
    # 부트로더 / BCD = 부팅 파티션
    foreach ($m in @('bootmgr', 'Boot\BCD', 'EFI\Microsoft\Boot\BCD', 'ntldr')) {
        if (Test-Path -LiteralPath (Join-Path $root $m)) { $reasons += '부팅 파티션'; break }
    }
    # 복구 이미지 / 설치 미디어
    foreach ($m in @('Recovery\WindowsRE\Winre.wim', 'sources\install.wim', 'sources\install.esd')) {
        if (Test-Path -LiteralPath (Join-Path $root $m) -PathType Leaf) { $reasons += '복구/설치 미디어'; break }
    }
    # 리눅스 루트 파일시스템이 마운트된 경우
    if ((Test-Path -LiteralPath (Join-Path $root 'etc\fstab')) -and
        (Test-Path -LiteralPath (Join-Path $root 'usr\bin'))) { $reasons += 'Linux 루트 파일시스템' }

    return @($reasons | Select-Object -Unique)
}

#--------------------------------------------------------------------
# 모든 볼륨을 훑어 백업 대상 여부와 그 사유를 계산
#--------------------------------------------------------------------
function Get-DriveCandidates {
    $sysDrive = ($env:SystemDrive).TrimEnd(':').ToUpper()
    $manual   = @($ExcludeDrives | ForEach-Object { $_.TrimEnd(':').ToUpper() })
    $out      = New-Object System.Collections.Generic.List[object]

    foreach ($d in (Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if (-not $d.DeviceID) { continue }
        $L      = $d.DeviceID.TrimEnd(':').ToUpper()
        $skip   = $null
        $sysHit = @()

        if     ($d.DriveType -eq 5)               { $skip = 'CD/DVD 드라이브' }
        elseif ($d.DriveType -eq 4)               { $skip = '네트워크 드라이브' }
        elseif ($d.DriveType -eq 6)               { $skip = 'RAM 디스크' }
        elseif ($d.DriveType -notin @(2,3))       { $skip = "지원하지 않는 DriveType($($d.DriveType))" }
        elseif (-not $d.Size)                     { $skip = '미디어 없음/준비 안 됨' }
        elseif ($L -eq $RootDriveLetter)          { $skip = '백업 저장 드라이브' }
        elseif ($L -eq $sysDrive)                 { $skip = '현재 부팅 OS 드라이브' }
        elseif ($manual -contains $L)             { $skip = '-ExcludeDrives 로 제외됨' }
        else {
            $sysHit = @(Test-SystemVolume $L)
            if ($sysHit.Count -and -not $IncludeSystemVolumes) { $skip = ($sysHit -join ' / ') }
        }

        $out.Add([pscustomobject]@{
            Letter   = $L
            Label    = $d.VolumeName
            Type     = switch ($d.DriveType) { 2 {'이동식'} 3 {'고정식'} 4 {'네트워크'} 5 {'CD/DVD'} 6 {'RAM'} default {"기타($($d.DriveType))"} }
            UsedGB   = if ($d.Size) { [math]::Round(($d.Size - $d.FreeSpace)/1GB,1) } else { $null }
            SizeGB   = if ($d.Size) { [math]::Round($d.Size/1GB,1) } else { $null }
            Backup   = [bool](-not $skip)
            Reason   = if ($skip) { $skip } else { '백업 대상' }
            SysHits  = ($sysHit -join ' / ')
        })
    }
    return $out
}

function Get-TargetDrives {
    # 주의: (빈 파이프라인).Letter 는 $null 을 돌려주고 @($null).Count 는 1 이 된다.
    # 그래서 반드시 ForEach-Object 로 풀어서 빈 배열이 나오도록 해야 한다.
    @(Get-DriveCandidates | Where-Object Backup | ForEach-Object { $_.Letter } |
        Where-Object { $_ -match '^[A-Za-z]$' })
}

function Show-Scan {
    Write-Host "`n===== 드라이브 스캔 결과 ====="
    Get-DriveCandidates |
        Select-Object @{n='드라이브';e={"$($_.Letter):"}}, @{n='라벨';e={$_.Label}}, @{n='종류';e={$_.Type}},
                      @{n='사용/전체GB';e={ if ($_.SizeGB) { "$($_.UsedGB)/$($_.SizeGB)" } else { '-' } }},
                      @{n='백업';e={ if ($_.Backup) { 'O' } else { 'X' } }}, @{n='사유';e={$_.Reason}} |
        Format-Table -AutoSize
    Write-Host "  (시스템 볼륨을 강제로 포함하려면 -IncludeSystemVolumes, 특정 드라이브만 빼려면 -ExcludeDrives E,F)`n"
}

function Get-DriveInfo([string]$L) {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${L}:'" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Serial = $d.VolumeSerialNumber
        Label  = $d.VolumeName
        SizeGB = if ($d.Size) { [math]::Round($d.Size/1GB,1) } else { $null }
    }
}

#--------------------------------------------------------------------
# 상태 파일 읽기/쓰기 (재개 로직의 핵심)
#--------------------------------------------------------------------
$script:statePath = $null
$script:state = $null

function Load-State([string]$L) {
    $metaDir = Join-Path $MetaRoot $L
    New-Item -ItemType Directory -Force -Path $metaDir | Out-Null
    $script:statePath = Join-Path $metaDir 'backup_state.json'
    $script:state = [ordered]@{
        DriveLetter           = $L
        Serial                = ''
        Label                 = ''
        LastPhase             = 'never'        # never | copying | committing | done | interrupted
        LastCopyStartedUtc    = ''
        LastCopyCompletedUtc  = ''
        Interrupted           = $false
        LastCommit            = ''
        LastCommitUtc         = ''
        SerialChangedWarning  = ''
        ExcludedTopDirs       = @()
        SystemScanUtc         = ''
        History               = @()
    }
    if (Test-Path $script:statePath) {
        try {
            $old = Get-Content $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $old.PSObject.Properties) { $script:state[$p.Name] = $p.Value }
        } catch { Write-Log "state 파일 손상 - 새로 시작: $L" 'WARN' }
    }
}

function Save-State {
    if ($script:state.History.Count -gt 50) {
        $script:state.History = @($script:state.History | Select-Object -Last 50)
    }
    ($script:state | ConvertTo-Json -Depth 6) | Set-Content -Path $script:statePath -Encoding UTF8
}

function Add-History([string]$phase, [string]$detail) {
    $script:state.History += [pscustomobject]@{
        Utc = (Get-Date).ToUniversalTime().ToString('o'); Phase = $phase; Detail = $detail
    }
}

#--------------------------------------------------------------------
# 파일 매니페스트 생성: 상대경로 -> 크기/수정시각(/해시)
# 검증 로직의 기본 재료. "메타데이터 대조"에 사용.
#--------------------------------------------------------------------
function Get-Manifest([string]$root, [switch]$WithHash,
                      [string[]]$SkipAnyDir = @(), [string[]]$SkipTopDir = @(), [string[]]$SkipFile = @()) {
    $table   = [ordered]@{}
    $rootLen = $root.TrimEnd('\').Length
    $anySet = @{}; foreach ($d in $SkipAnyDir) { if ($d) { $anySet[$d.ToLowerInvariant()] = $true } }
    $topSet = @{}; foreach ($d in $SkipTopDir) { if ($d) { $topSet[$d.ToLowerInvariant()] = $true } }
    $filSet = @{}; foreach ($f in $SkipFile)   { if ($f) { $filSet[$f.ToLowerInvariant()] = $true } }
    $anySet['.git'] = $true   # 백업본 쪽 .git 은 항상 제외

    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel   = $_.FullName.Substring($rootLen).TrimStart('\')
            $parts = $rel.Split('\')
            if ($filSet.ContainsKey($parts[$parts.Count-1].ToLowerInvariant())) { return }
            if ($parts.Count -gt 1 -and $topSet.ContainsKey($parts[0].ToLowerInvariant())) { return }
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if ($anySet.ContainsKey($parts[$i].ToLowerInvariant())) { return }
            }
            $h = $null
            if ($WithHash) {
                try { $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $h = 'ERR' }
            }
            $table[$rel] = [ordered]@{
                len   = $_.Length
                mtime = $_.LastWriteTimeUtc.ToString('o')
                sha   = $h
            }
        }
    return $table
}

#--------------------------------------------------------------------
# 핵심: 드라이브 1개 백업 (재개 가능 + git 커밋)
#--------------------------------------------------------------------
function Invoke-DriveBackup([string]$L) {
    if ($L -notmatch '^[A-Za-z]$') { Write-Log "잘못된 드라이브 문자('$L') - 건너뜁니다." 'ERROR'; return }
    $L = $L.ToUpper()
    if (-not (Test-Path -LiteralPath "${L}:\")) { Write-Log "${L}: 드라이브에 접근할 수 없습니다 - 건너뜁니다." 'ERROR'; return }
    $src  = "${L}:\"
    $dst  = Join-Path $BackupRoot "$L`_"
    $meta = Join-Path $MetaRoot $L
    New-Item -ItemType Directory -Force -Path $dst, $meta | Out-Null
    Load-State $L

    $info = Get-DriveInfo $L
    # 같은 문자에 다른 장치가 꽂힌 경우 경고 (폴더는 문자 기준 유지, 이력은 git이 관리)
    if ($script:state.Serial -and $info.Serial -and ($script:state.Serial -ne $info.Serial)) {
        $script:state.SerialChangedWarning = "이전 시리얼 $($script:state.Serial) != 현재 $($info.Serial) - 다른 장치일 수 있음"
        Write-Log "$L : $($script:state.SerialChangedWarning)" 'WARN'
    } else { $script:state.SerialChangedWarning = '' }
    $script:state.Serial = $info.Serial
    $script:state.Label  = $info.Label

    # 시스템 디렉터리 제외 범위는 최초 1회만 확정해서 state에 고정.
    # 매번 재탐지하면 마운트 지연/권한 오류로 범위가 흔들려 재개·검증이 불안정해진다.
    if (-not $script:state.SystemScanUtc -or $script:state.SerialChangedWarning) {
        $sys = Get-DriveSystemDirs $L
        $script:state.ExcludedTopDirs = @($sys.TopDirs)
        $script:state.SystemScanUtc   = (Get-Date).ToUniversalTime().ToString('o')
        Save-State
        if ($sys.IsOsVolume)    { Write-Log "$L : OS 설치 볼륨으로 감지됨 (시스템 폴더 제외)" 'WARN' }
        if ($sys.TopDirs.Count) { Write-Log "$L : 시스템 디렉터리 제외 확정 -> $($sys.TopDirs -join ', ')" 'WARN' }
    }
    $topSkip = @($script:state.ExcludedTopDirs)

    if ($script:state.Interrupted) {
        Write-Log "$L : 지난번 중단된 백업이 있습니다. 완료된 파일은 건너뛰고 이어서 진행합니다 (robocopy 재개)"
    }

    # 최초 백업이면 용량이 충분한지 먼저 확인 (자동 감지로 큰 드라이브가 잡혔을 때 C: 가 꽉 차는 것 방지)
    if (-not $NoSpaceCheck -and $script:state.LastPhase -eq 'never') {
        $srcVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${L}:'" -ErrorAction SilentlyContinue
        $dstVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${RootDriveLetter}:'" -ErrorAction SilentlyContinue
        if ($srcVol -and $dstVol) {
            $needGB  = [math]::Round(($srcVol.Size - $srcVol.FreeSpace)/1GB, 1)
            $availGB = [math]::Round($dstVol.FreeSpace/1GB, 1)
            if ($needGB -gt ($availGB - $FreeMarginGB)) {
                Write-Log ("{0} : 공간 부족으로 백업 중단 - 필요 약 {1}GB / {2}: 여유 {3}GB (여유분 {4}GB 확보 필요). 무시하려면 -NoSpaceCheck" -f $L, $needGB, $RootDriveLetter, $availGB, $FreeMarginGB) 'ERROR'
                $script:state.LastPhase = 'never'; Save-State
                return
            }
        }
    }

    # ---------------- Phase 1: 파일 복사 (robocopy) ----------------
    # 재개 원리:
    #  - /E 또는 /MIR 재실행 시 크기+타임스탬프가 같은 파일은 자동 skip
    #    => 장치를 뺐다 껴도 "처음부터"가 아니라 "남은 것만" 복사
    #  - /Z : restartable 모드 - 큰 파일 복사 중 끊기면 그 파일도 중간 지점부터 재개
    $script:state.LastPhase = 'copying'
    $script:state.LastCopyStartedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-State

    $rcLog  = Join-Path $meta ("robocopy_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    $rcMode = if ($Mirror) { '/MIR' } else { '/E' }
    $xdAbs  = @(foreach ($d in $topSkip) { Join-Path $src $d })   # 최상위만 제외하도록 절대경로로 전달
    $rcArgs = @($src, $dst, $rcMode, '/Z', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:2', '/XJ', '/NP', '/NDL', '/BYTES',
                '/XD') + $ExcludeDirs + $xdAbs + @('/XF') + $ExcludeFiles + @("/UNILOG+:$rcLog")
    Write-Log "$L : robocopy 시작 ($rcMode)"
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    # robocopy 종료코드: 0~7 = 성공(복사/추가/불일치 포함), 8 이상 = 실패(끊김/오류)
    if ($code -ge 8) {
        $script:state.Interrupted = $true
        $script:state.LastPhase   = 'interrupted'
        Add-History 'interrupted' "robocopy exit $code"
        Save-State
        Write-Log "$L : 백업 중단 (robocopy exit $code). 장치를 다시 꽂으면 이어서 진행됩니다." 'WARN'
        return
    }

    $script:state.Interrupted = $false
    $script:state.LastCopyCompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Add-History 'copied' "robocopy exit $code"
    Write-Log "$L : 복사 완료 (exit $code)"

    # 완료 시점의 드라이브 매니페스트 저장
    # => 장치를 뽑은 뒤에도 "지난 백업에 무엇이 얼마나 들어왔는지" 계산 가능
    Write-Log "$L : 매니페스트 저장 중..."
    $manifest = Get-Manifest $src -SkipAnyDir $ExcludeDirs -SkipTopDir $topSkip -SkipFile $ExcludeFiles
    ($manifest | ConvertTo-Json -Depth 4 -Compress) | Set-Content (Join-Path $meta 'manifest.json') -Encoding UTF8

    # ---------------- Phase 2: git 커밋 누적 ----------------
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log "$L : git을 찾을 수 없습니다. https://git-scm.com 에서 설치 후 다시 실행하세요." 'ERROR'
        $script:state.LastPhase = 'interrupted'; Save-State; return
    }
    $script:state.LastPhase = 'committing'
    Save-State

    if (-not (Test-Path (Join-Path $dst '.git'))) {
        & git -C $dst init -b main | Out-Null
        & git -C $dst config core.autocrlf false
        & git -C $dst config core.longpaths true
        & git -C $dst config core.quotepath false
        & git -C $dst config core.untrackedCache true
        & git -C $dst config core.fscache true
        Write-Log "$L : git 저장소 초기화"
    }

    & git -C $dst add -A
    $pending = & git -C $dst status --porcelain
    if ($pending) {
        $msg = "backup ${L}: {0:yyyy-MM-dd HH:mm:ss} [{1} / {2}]" -f (Get-Date), $info.Label, $info.Serial
        & git -C $dst commit -m "$msg" --quiet
        $script:state.LastCommit    = (& git -C $dst rev-parse --short HEAD)
        $script:state.LastCommitUtc = (Get-Date).ToUniversalTime().ToString('o')
        Add-History 'committed' $script:state.LastCommit
        Write-Log "$L : git 커밋 완료 ($($script:state.LastCommit))"
    } else {
        Write-Log "$L : 변경사항 없음 - 커밋 생략"
        Add-History 'no-change' ''
    }

    $script:state.LastPhase = 'done'
    Save-State
    Write-Log "$L : 백업 사이클 완료"
}

#--------------------------------------------------------------------
# 검증: 백업본 vs 현재 드라이브 (메타데이터/수정기록 대조)
#--------------------------------------------------------------------
function Invoke-Verify([string]$L) {
    if ($L -notmatch '^[A-Za-z]$') { Write-Log "잘못된 드라이브 문자('$L') - 건너뜁니다." 'ERROR'; return }
    $L = $L.ToUpper()
    $dst  = Join-Path $BackupRoot "$L`_"
    $meta = Join-Path $MetaRoot $L
    if (-not (Test-Path $dst)) { Write-Log "$L : 백업본이 없습니다." 'ERROR'; return }
    Load-State $L

    Write-Host "`n===== 검증: 드라이브 ${L}: ====="

    # (1) 백업본 내부 무결성: 마지막 커밋 이후 백업본이 변조/잘림 없이 그대로인지
    if (Test-Path (Join-Path $dst '.git')) {
        $dirty = & git -C $dst status --porcelain
        if ($dirty) {
            Write-Host "  [경고] 백업본이 마지막 커밋 이후 변경되었습니다 (잘림/수동수정 가능성):"
            $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host "  [OK] 백업본 = 마지막 git 커밋 상태와 일치 (내부 변조 없음)"
        }
        Write-Host "  최근 커밋:"; & git -C $dst log --oneline -5 | ForEach-Object { Write-Host "    $_" }
    }

    # (2) 지난 백업 시점 매니페스트 vs 백업본 -> "어느 지점까지 들어왔는지"
    $manifestPath = Join-Path $meta 'manifest.json'
    $lastSnap = $null
    if (Test-Path $manifestPath) {
        $lastSnap = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    # (3) 현재 드라이브 vs 백업본 -> "변경/수정 발생 여부 + 남은 양"
    $drivePresent = Test-Path "${L}:\"
    if (-not $drivePresent) {
        Write-Host "  [알림] 현재 ${L}: 드라이브가 연결되어 있지 않습니다."
        Write-Host "         마지막 완료 시점: $($script:state.LastCopyCompletedUtc) / 커밋: $($script:state.LastCommit)"
        if ($script:state.Interrupted) { Write-Host "         상태: 중단됨 - 다시 꽂으면 이어서 백업됩니다." }
        return
    }

    Write-Host "  스캔 중... (파일 수에 따라 시간 소요)"
    $vTop     = @($script:state.ExcludedTopDirs)
    $driveNow = Get-Manifest "${L}:\" -WithHash:$DeepHash -SkipAnyDir $ExcludeDirs -SkipTopDir $vTop -SkipFile $ExcludeFiles
    $backup   = Get-Manifest $dst      -WithHash:$DeepHash -SkipAnyDir $ExcludeDirs -SkipTopDir $vTop -SkipFile $ExcludeFiles
    if ($vTop.Count) { Write-Host ("  제외된 시스템 폴더: {0}" -f ($vTop -join ', ')) }

    $report = New-Object System.Collections.Generic.List[object]
    $pendingBytes = 0L
    $allKeys = @(@($driveNow.Keys) + @($backup.Keys) | Select-Object -Unique)
    foreach ($rel in $allKeys) {
        $d = $driveNow[$rel]; $b = $backup[$rel]
        $status = 'OK'
        if     ($d -and -not $b) { $status = 'OnlyOnDrive(미백업)';  $pendingBytes += $d.len }
        elseif ($b -and -not $d) { $status = 'OnlyInBackup(드라이브에서 삭제됨)' }
        elseif ($d.len -ne $b.len) { $status = 'SizeMismatch(수정/잘림 의심)'; $pendingBytes += $d.len }
        elseif ($d.mtime -ne $b.mtime) { $status = 'TimeOnlyMismatch(메타데이터 상이)' }
        elseif ($DeepHash -and $d.sha -and $b.sha -and ($d.sha -ne $b.sha)) { $status = 'HashMismatch(내용 상이)' }
        if ($status -ne 'OK') {
            $report.Add([pscustomobject]@{
                Status = $status; RelativePath = $rel
                DriveSize = if ($d){$d.len}else{$null}; BackupSize = if ($b){$b.len}else{$null}
                DriveMTimeUtc = if ($d){$d.mtime}else{$null}; BackupMTimeUtc = if ($b){$b.mtime}else{$null}
                DriveSha = if ($d){$d.sha}else{$null}; BackupSha = if ($b){$b.sha}else{$null}
            })
        }
    }

    $csv = Join-Path $meta ("verify_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    $report | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

    $cnt = $report | Group-Object Status | Sort-Object Count -Descending
    Write-Host "`n  ---- 결과 요약 ----"
    Write-Host ("  드라이브 파일 수: {0} / 백업본 파일 수: {1}" -f $driveNow.Count, $backup.Count)
    if ($cnt) {
        foreach ($g in $cnt) { Write-Host ("  {0}: {1}개" -f $g.Name, $g.Count) }
        Write-Host ("  아직 백업에 반영 안 된 데이터: 약 {0:N1} MB" -f ($pendingBytes/1MB))
        Write-Host "  상세 내역 CSV: $csv"
    } else {
        Write-Host "  [OK] 변경/수정 사항 없음 - 백업본이 드라이브와 완전히 일치합니다."
    }

    # TimeOnlyMismatch는 NTFS 타임스탬프 정밀도 차이일 수 있으므로 -DeepHash로 재검증 권장
    if (-not $DeepHash -and ($report | Where-Object Status -like 'TimeOnly*')) {
        Write-Host "  [팁] 시간만 다른 파일은 -DeepHash 옵션으로 실제 내용까지 비교할 수 있습니다."
    }
}

#--------------------------------------------------------------------
# 상태 요약
#--------------------------------------------------------------------
function Show-Status {
    Write-Host "`n===== 드라이브별 백업 상태 ====="
    Get-ChildItem $MetaRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $sp = Join-Path $_.FullName 'backup_state.json'
        if (Test-Path $sp) {
            $s = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
            [pscustomobject]@{
                Drive        = "$($s.DriveLetter):"
                Label        = $s.Label
                Phase        = $s.LastPhase
                Interrupted  = $s.Interrupted
                LastCopyUtc  = $s.LastCopyCompletedUtc
                LastCommit   = $s.LastCommit
            }
        }
    } | Format-Table -AutoSize
}

#--------------------------------------------------------------------
# 감시 루프: 드라이브 도착 감지 -> 백업 프로세스를 백그라운드로 분리 실행
#--------------------------------------------------------------------
function Start-Watch {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log "git이 설치되어 있지 않습니다. 커밋 단계는 건너뛰게 됩니다. 설치 권장: https://git-scm.com" 'WARN'
    }
    Write-Log "감시 시작 (백업 루트: $BackupRoot / 제외 드라이브: ${RootDriveLetter}: / 주기: ${PollSeconds}s)"
    $present = @{}
    $lastTriggered = @{}
    while ($true) {
        try {
            $drives = @(Get-TargetDrives)
            foreach ($L in $drives) {
                if (-not $present[$L]) {
                    $present[$L] = $true
                    $cool = $lastTriggered[$L]
                    if (-not $cool -or ((Get-Date) - $cool).TotalSeconds -gt $CooldownSeconds) {
                        $lastTriggered[$L] = Get-Date
                        Write-Log "${L}: 드라이브 감지 -> 백그라운드 백업 시작"
                        $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode BackupNow -Letter $L -BackupRoot `"$BackupRoot`""
                        if ($Mirror) { $argList += ' -Mirror' }
                        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList
                    }
                }
            }
            foreach ($k in @($present.Keys)) {
                if ($drives -notcontains $k) { $present[$k] = $false; Write-Log "${k}: 드라이브 제거됨" }
            }
        } catch {
            Write-Log "감시 루프 오류: $($_.Exception.Message)" 'ERROR'
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

#--------------------------------------------------------------------
# 진입점
#--------------------------------------------------------------------
switch ($Mode) {
    'Watch'     { Start-Watch }
    'Scan'      { Show-Scan }
    'BackupNow' {
        if ($Letter) {
            $L = $Letter.TrimEnd(':').ToUpper()
            if (-not (Test-Path "${L}:\")) { Write-Log "${L}: 드라이브가 없습니다." 'ERROR'; exit 1 }
            # 수동 지정이라도 시스템 볼륨이면 경고하고 중단 (-IncludeSystemVolumes 로 강제 가능)
            $hit = @(Test-SystemVolume $L)
            if ($hit.Count -and -not $IncludeSystemVolumes) {
                Write-Log ("{0}: 시스템 볼륨으로 감지되어 건너뜁니다 ({1}). 강제하려면 -IncludeSystemVolumes" -f $L, ($hit -join ' / ')) 'ERROR'
                exit 1
            }
            if ($L -eq $RootDriveLetter) { Write-Log "${L}: 백업 저장 드라이브 자신은 백업할 수 없습니다." 'ERROR'; exit 1 }
            Invoke-DriveBackup $L
        }
        else {
            # -Letter 생략 시: 시스템 볼륨을 제외한 모든 대상 드라이브를 자동으로 백업
            $targets = @(Get-TargetDrives)
            if (-not $targets.Count) {
                Write-Log "백업 대상 드라이브가 없습니다. 'Scan' 모드로 제외 사유를 확인하세요." 'WARN'
                Show-Scan
                exit 1
            }
            Write-Log ("자동 감지된 백업 대상: {0}" -f (($targets | ForEach-Object { "${_}:" }) -join ', '))
            foreach ($t in $targets) { Invoke-DriveBackup $t }
        }
    }
    'Verify'    {
        if ($Letter) { Invoke-Verify ($Letter.TrimEnd(':').ToUpper()) }
        else {
            $targets = @(Get-TargetDrives)
            if (-not $targets.Count) { Write-Host "검증할 대상 드라이브가 없습니다."; exit 1 }
            foreach ($t in $targets) { Invoke-Verify $t }
        }
    }
    'Status'    { Show-Status }
}
