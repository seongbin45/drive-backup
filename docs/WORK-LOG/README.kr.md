# WORK-LOG

drive-backup 프로젝트를 개발하면서 AI 어시스턴트와 나눈 작업 대화를 보존한 로그 디렉터리입니다.

## 파일 목록

| 파일 | 내용 |
|---|---|
| `26-09-15-work-log-with-claude.txt` | Claude와의 작업 로그. PowerShell 5.1 호환성 수정(`??` 연산자 제거), UTF-8 BOM 인코딩 이슈, 시스템 디렉터리 제외 로직에 대한 교차검증 |
| `26-09-15-work-log-with-gemini.txt` | Gemini와의 작업 로그. 동일 이슈에 대한 교차검증 및 시스템 볼륨 판정 로직(`Test-Path` 기반 시그니처 검사) 설계 논의 |

## 파일 명명 규칙

```
YY-MM-DD-work-log-with-<AI이름>.txt
```

## 주요 다룬 주제 (2026-09-15 로그 기준)

- **PowerShell 5.1 구문 오류 수정**: null-coalescing 연산자(`??`)는 PowerShell 7.0부터 지원되므로 5.1에서는 `if-else`로 대체해야 함
- **인코딩**: 스크립트 파일은 반드시 UTF-8 with BOM으로 저장 (BOM 없으면 CP949로 잘못 읽힘)
- **시스템 디렉터리 제외**: 폴더 이름이 아닌 실제 시스템 파일(`ntoskrnl.exe`, `bootmgr` 등)의 존재 여부로 OS/부팅/복구 볼륨을 판정해 백업 대상에서 제외하는 로직
- **교차검증**: 한 AI가 제안한 수정 코드에 새로운 구문 오류(개행 누락)가 포함된 사례 등, AI 응답을 맹신하지 않고 상호 검증한 기록
