# npm-reorg-guard

> Blockchain reorg concept applied to npm package security for Claude Code

## Concept

블록체인에서 **reorg(reorganization)** 는 특정 블록 이후의 체인을 무효화하고, 이전의 안전한 상태로 되돌리는 메커니즘입니다.

`npm-reorg-guard`는 이 개념을 npm 패키지 관리에 적용합니다:

```
[Safe State] → npm install → [New State] → 검증 실패 → REORG → [Safe State]
     ↑                                                           ↑
     └── package-lock.json 스냅샷 ─────────────────── 롤백 ──────┘
```

1. **스냅샷 (Block Checkpoint)**: `npm install` 실행 전, 현재 `package-lock.json`의 해시와 사본을 저장합니다.
2. **검증 (Block Validation)**: 설치 후, 변경된 lock 파일과 새 패키지들을 보안 규칙으로 검증합니다.
3. **리오그 (Chain Reorganization)**: 의심스러운 변경이 감지되면, 스냅샷으로 자동 롤백합니다.

## How It Works

Claude Code의 Hook 시스템을 활용합니다:

### PreToolUse Hook (`guard.sh`)

- Claude가 `npm install`, `pnpm add` 등의 명령을 실행하기 전에 가로챕니다
- 현재 lock 파일의 안전 스냅샷을 `~/.npm-reorg-guard/snapshots/`에 저장합니다
- 명령 자체의 위험성도 사전 검사합니다:
  - 원격 스크립트 파이프 실행 (`curl | bash`)
  - 비표준 레지스트리 사용
  - 타이포스쿼팅 패턴 패키지명

### PostToolUse Hook (`verify.sh`)

- `npm install` 완료 후, 변경 사항을 분석합니다
- 감지하는 위협 패턴:
  - **악성 install 스크립트**: `postinstall`, `preinstall`에서 네트워크 접근, 코드 실행, 민감 경로 접근
  - **비표준 레지스트리**: `resolved` URL이 공식 npm 레지스트리가 아닌 곳을 가리킴
  - **난독화 코드**: base64 인코딩, hex escape 등
  - **의존성 폭발**: 비정상적으로 많은 새 의존성 추가
  - **네이티브 바이너리**: node_modules 내 컴파일된 실행 파일
- 위협 감지 시 자동으로 스냅샷 상태로 롤백(reorg)합니다

## Installation

### Prerequisites

- Claude Code (with Hook support)
- `jq` (JSON parser)
- `shasum` or `sha256sum`

### Setup

1. Clone this repository:

```bash
git clone https://github.com/your-org/npm-reorg-guard.git
cp -r npm-reorg-guard ~/.claude/skills/
```

2. Add hooks to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hook": "~/.claude/skills/npm-reorg-guard/scripts/guard.sh"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hook": "~/.claude/skills/npm-reorg-guard/scripts/verify.sh"
      }
    ]
  }
}
```

3. Verify installation:

```bash
# guard.sh and verify.sh should be executable
ls -la ~/.claude/skills/npm-reorg-guard/scripts/
```

## Logs & Snapshots

- **Reorg log**: `~/.npm-reorg-guard/reorg.log`
- **Snapshots**: `~/.npm-reorg-guard/snapshots/`
- Only the 10 most recent snapshots are retained

```bash
# View reorg history
cat ~/.npm-reorg-guard/reorg.log

# List snapshots
ls -la ~/.npm-reorg-guard/snapshots/
```

## Detection Rules

| Category | Pattern | Action |
|----------|---------|--------|
| Typosquatting | Known misspelling patterns | Block (PreToolUse) |
| Pipe execution | `curl \| bash` | Block (PreToolUse) |
| Non-standard registry | `--registry` with unknown host | Block (PreToolUse) |
| Malicious install script | Network access in postinstall | Reorg (PostToolUse) |
| Code execution | eval/exec in install script | Reorg (PostToolUse) |
| Sensitive path access | .ssh, .env, .aws access | Reorg (PostToolUse) |
| Obfuscated code | base64, hex encoding | Reorg (PostToolUse) |
| Dependency explosion | 50+ new dependencies | Reorg (PostToolUse) |
| Native binary | Compiled binary in node_modules | Reorg (PostToolUse) |
| Insecure URL | http:// or git:// resolved URL | Reorg (PostToolUse) |

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
