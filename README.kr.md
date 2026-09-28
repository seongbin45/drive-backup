# drive-backup

USB / 외장 HDD·SSD를 꽂으면 자동으로 감지해 로컬 디스크에 백업하고, 백업 이력을 Git 커밋으로 누적 관리하는 Windows 자동 백업 프로젝트입니다.

## 개요

- **자동 감지**: 이동식/고정식 드라이브가 연결되면 자동으로 백업 대상인지 판별합니다.
- **백그라운드 자동 백업**: Windows 작업 스케줄러 기반으로 5분 주기 무인 실행됩니다.
- **Git 이력 관리**: 백업본 폴더가 Git 저장소로 관리되어 삭제·변경 이력을 과거 시점으로 되돌릴 수 있습니다.
- **중단 후 재개**: robocopy 재개 기능으로 백업 도중 장치를 뽑아도 다시 꽂으면 이어서 진행됩니다.
- **검증**: 메타데이터(크기/수정시각) 대조 및 SHA-256 해시 대조로 백업본과 원본의 일치 여부를 확인합니다.
- **시스템 볼륨 자동 제외**: Windows 설치 볼륨, 부팅 파티션, 복구/설치 미디어, Linux 루트 파일시스템은 실제 시스템 파일 시그니처로 판정해 백업 대상에서 자동으로 걸러냅니다.

## 디렉터리 구조

```
drive-backup/
├── README.md            <- 이 파일 (프로젝트 개요)
├── Tools/               <- 백업 자동화 PowerShell 스크립트
│   ├── AutoDriveBackup.ps1        <- 핵심 백업/감시/검증 스크립트
│   ├── Register-AutoBackupTask.ps1 <- 작업 스케줄러 등록 스크립트
│   └── README.md                  <- Tools 운영상 주의사항 및 알려진 위험
└── docs/                <- 프로젝트 문서
    └── WORK-LOG/        <- AI 어시스턴트와의 개발 작업 로그
```

## 요구 사항

- Windows 10/11, **Windows PowerShell 5.1** 이상
- [Git for Windows](https://git-scm.com) (커밋 이력 기능에 필요)
- 스크립트 파일은 반드시 **UTF-8 with BOM**으로 저장할 것 (BOM이 없으면 PowerShell 5.1이 CP949로 잘못 읽어 구문 오류 발생)

## 빠른 시작

```powershell
# 1. 실행 정책 허용 (현재 사용자에 한함)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. 어떤 드라이브가 백업 대상인지 스캔 (아무것도 변경하지 않음)
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\AutoDriveBackup.ps1 -Mode Scan

# 3. 관리자 권한 PowerShell에서 작업 스케줄러 등록 (5분 주기 자동 백업)
.\Tools\Register-AutoBackupTask.ps1

# 4. 상태 확인
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\AutoDriveBackup.ps1 -Mode Status
```

## 백업 결과물 구조 (기본값 `C:\DriveBackup`)

```
C:\DriveBackup\
├── O_\                  <- O: 드라이브 백업본 (Git 저장소)
├── E_\                  <- E: 드라이브 백업본 (Git 저장소)
└── _meta\               <- 상태/로그/매니페스트 (백업본 밖에 둠)
    ├── watcher.log      <- 감시/실행 로그
    └── O_\
        ├── backup_state.json   <- 재개/상태 정보
        ├── manifest.json       <- 지난 백업 완료 시점의 파일 목록
        ├── robocopy_*.log      <- 복사 로그
        └── verify_*.csv        <- 검증 결과 상세 내역
```

## ⚠️ 알려진 주요 위험

> 상세한 내용은 `Tools/README.md`를 반드시 읽어보세요.

1. **드라이브 문자 기반 폴더명**: USB를 여러 개 바꿔 쓰면 같은 문자를 배정받아 백업본이 섞일 수 있습니다. 볼륨 시리얼 기반 폴더 전환이 예정된 개선 사항입니다.
2. **`-Mirror` 옵션 주의**: 삭제 전파를 켜면 다른 장치가 같은 문자를 배정받았을 때 기존 백업본이 통째로 삭제될 수 있습니다. 기본값(삭제 전파 안 함) 사용을 권장합니다.
3. **로그 무한 증가**: 로그 회전 로직이 없어 `watcher.log`와 `robocopy_*.log`가 계속 쌓입니다.
