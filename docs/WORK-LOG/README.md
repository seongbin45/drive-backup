
Languages: [English](./README.md) | [한국어](./README.kr.md)

# WORK-LOG

A log directory preserving the working conversations with AI assistants during the development of the drive-backup project.

## File List

| File | Contents |
|---|---|
| `26-09-15-work-log-with-claude.txt` | Work log with Claude. Cross-verification on PowerShell 5.1 compatibility fixes (removing the `??` operator), the UTF-8 BOM encoding issue, and system-directory exclusion logic |
| `26-09-15-work-log-with-gemini.txt` | Work log with Gemini. Cross-verification of the same issues and design discussion of the system volume detection logic (`Test-Path`-based signature checks) |

## File Naming Convention

```
YY-MM-DD-work-log-with-<AI-name>.txt
```

## Key Topics Covered (as of the 2026-09-15 logs)

- **PowerShell 5.1 syntax error fixes**: The null-coalescing operator (`??`) is only supported from PowerShell 7.0, so it must be replaced with `if-else` in 5.1
- **Encoding**: Script files must be saved as UTF-8 with BOM (without BOM they are misread as CP949)
- **System directory exclusion**: Logic that detects OS/boot/recovery volumes by the presence of actual system files (`ntoskrnl.exe`, `bootmgr`, etc.) rather than folder names, and excludes them from backup targets
- **Cross-verification**: Records of mutual verification instead of blindly trusting AI responses — e.g., a case where a fix proposed by one AI contained a new syntax error (a missing line break)
