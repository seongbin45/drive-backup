## 이 계획에는 실제 사고로 이어질 구멍이 하나 있습니다

**"USB를 여러 개 바꿔가며 쓰겠다"가 지금 설계와 정면으로 충돌합니다.** 백업본 폴더명이 **드라이브 문자** 기준(`E_`, `F_`)입니다. USB A를 뽑고 USB B를 꽂으면 Windows가 같은 문자를 배정하는 경우가 흔하고, 그러면:

- 두 장치의 파일이 `C:\DriveBackup\E_` 한 폴더에 **섞입니다**
- git 이력도 한 저장소에 뒤섞여, 나중에 "어느 USB의 어느 시점"인지 분리가 불가능해집니다
- `-Mirror`를 켰다면 USB B 백업이 시작되는 순간 **USB A의 백업본이 전부 삭제**됩니다

현재 코드는 시리얼이 바뀌면 `SerialChangedWarning` 로그 한 줄만 남기고 그대로 진행합니다. 5분마다 무인으로 도는 상황에서 그 경고를 볼 사람은 없습니다. **잃어버린 USB를 복구하려고 만드는 시스템인데, 정작 그 USB의 백업이 다음 USB에 덮여 사라지는 구조입니다.**

해결은 폴더명을 **볼륨 시리얼 기준**으로 바꾸는 것입니다(`E_` → `VOL-A1B2C3D4`). 다만 이건 `Invoke-DriveBackup`, `Invoke-Verify`, `Show-Status`, `Load-State`를 모두 손봐야 하고 기존 `D_` 백업본 마이그레이션도 필요합니다. **스케줄러를 붙이기 전에 이걸 먼저 하는 게 순서상 맞습니다.** 지금 등록해서 돌리면 USB를 두 개째 꽂는 순간부터 오염이 쌓입니다.

우선은 **`-Mirror`를 절대 켜지 마세요.** 그것만으로 "삭제"는 막힙니다(섞이는 건 여전합니다).

---

## 요청하신 트리거에 대한 판단

**"5분마다 무기한" + 나머지 트리거는 대부분 중복입니다.** 5분 반복 하나로 부팅/로그온/잠금해제 이후 상황이 전부 커버됩니다. 그래도 즉시성 때문에 시작·로그온·잠금해제는 넣었습니다. 대신:

- **"유휴 상태에서 깨어남"은 작업 스케줄러 기본 트리거에 없습니다.** 절전 복귀는 `Kernel-Power` 이벤트 기반 트리거로만 가능하고, 5분 주기가 이미 있으므로 추가 가치가 거의 없어 넣지 않았습니다.
- **`-Mode Watch`를 쓰지 않았습니다.** Watch는 5초마다 폴링하는 상주 루프인데 5분 반복과 겹치면 프로세스가 무한히 쌓입니다. `-Mode BackupNow`(1회 실행)로 바꿨습니다. 상주 프로세스가 없으니 죽어도 다음 주기에 스스로 복구됩니다.

## 창이 안 뜨게 하는 방법

`-WindowStyle Hidden`은 콘솔이 잠깐 깜빡일 수 있습니다. 확실한 방법은 **S4U 로그온 유형**("사용자 로그온 여부와 관계없이 실행")입니다. 세션 0에서 실행되어 창이 아예 생기지 않습니다. 등록 실패 시 자동으로 Interactive로 폴백하도록 했습니다.

## 넣은 안전장치

| 설정 | 이유 |
|---|---|
| `MultipleInstances = IgnoreNew` | **가장 중요.** 백업이 5분 넘게 걸리면 프로세스가 겹쳐 쌓입니다. 이전 실행이 안 끝나면 새 실행을 건너뜁니다 |
| `ExecutionTimeLimit 4시간` | IgnoreNew와 짝. 한 번 멈춘 인스턴스가 영원히 후속 실행을 막는 것을 방지 |
| `Priority 7` | 낮은 I/O 우선순위. 5분마다 전체 스캔이 도는데 작업 중 체감 렉을 줄임 |
| 시작 트리거 2분 지연 | 부팅 직후 디스크 혼잡 회피 |
| 등록 전 구문 검사 + BOM 검사 | 깨진 스크립트를 올리면 5분마다 조용히 실패만 반복합니다. 그동안 백업은 0입니다 |

## 등록

```powershell
# 관리자 권한 PowerShell
cd C:\Tools
```
```powershell
.\Register-AutoBackupTask.ps1
```
```powershell
# PowerShell 실행 정책 차단 해제 (현재 터미널에만 적용)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```
```powershell
Start-ScheduledTask -TaskName 'AutoDriveBackup'
```
```powershell
Get-ScheduledTask -TaskName 'AutoDriveBackup' | Get-ScheduledTaskInfo
```
```powershell
Get-Content C:\DriveBackup\_meta\watcher.log -Tail 20
```

`LastTaskResult`가 `0`이면 정상입니다. 기기 A는 현재 대상이 0개이므로 로그에 "백업 대상 드라이브가 없습니다"만 반복 기록됩니다 — 이게 정상 상태입니다.

## 남은 위험 3 가지

- **로그 무한 증가.** 5분마다 = 하루 288줄, `watcher.log`는 회전 로직이 없습니다. `robocopy_*.log`도 실행마다 새로 생겨 하루 288개씩 쌓입니다. 한 달이면 8천 개입니다. 로그 회전을 넣어야 합니다.

- **아무 USB나 백업됩니다.** 남의 USB, 부팅 디스크, 카메라 SD카드까지 자동으로 C:에 복사됩니다. 용량 가드가 최초 1회만 검사하므로 작은 USB 여러 개가 누적되면 막지 못합니다.

- **PowerShell 실행 정책이 차단합니다** 다른 PC에서 스크립트 파일(`.ps1`) 을 가져오면, Windows PowerShell의 기본 보안 설정(실행 정책, Execution Policy)에서 실행 자체를 차단합니다. 

## PowerShell 정책 차단 문제 해결 방법

PowerShell 정책 차단 문제를 해결하려면 스크립트 실행 권한을 변경해야 합니다.

**해결 방법:**
PowerShell 터미널에 아래 명령어를 입력하고 Enter를 누르세요. 확인 프롬프트가 나타나면 `Y`를 입력하시면 됩니다.

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

> **설명:** 이 명령어는 현재 사용자 환경에 한해 로컬에 저장된 스크립트 실행을 허용합니다.

위 명령어를 적용한 후 스크립트를 다시 실행해 보시기 바랍니다.

시리얼 기반 폴더 전환과 로그 회전 중 어느 쪽부터 할지 알려주시면 이어서 작업하겠습니다.