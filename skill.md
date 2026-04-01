---
name: npm-reorg-guard
description: Blockchain reorg concept applied to npm package security — snapshots lock files before installs and auto-rollbacks on suspicious changes
hooks:
  - type: PreToolUse
    script: scripts/guard.sh
  - type: PostToolUse
    script: scripts/verify.sh
---

# npm-reorg-guard

블록체인 reorg 개념을 npm 보안에 적용한 Claude Code 스킬입니다.

## 작동 원리

1. `npm install`, `pnpm add` 등 패키지 설치 명령 감지 시, 현재 lock 파일의 "안전 스냅샷"을 저장합니다.
2. 설치 완료 후, 변경된 lock 파일을 분석하여 의심스러운 패턴을 탐지합니다.
3. 의심스러운 변경이 발견되면 자동으로 이전 안전 상태로 롤백(reorg)합니다.

## 감지하는 위협

- 비표준 npm 레지스트리로의 resolved URL
- 패키지 install 스크립트 내 네트워크 접근
- install 스크립트 내 코드 실행 (eval, exec, child_process)
- 민감한 경로 접근 시도 (.ssh, .env, .aws, credentials)
- 난독화된 코드 (base64, hex encoding)
- 비정상적으로 많은 새 의존성 추가
- node_modules 내 네이티브 바이너리
- 타이포스쿼팅 패턴의 패키지명
- 비보안(non-HTTPS) resolved URL

## 설치 방법

### 1. 스킬 디렉토리에 복사

```bash
# 프로젝트 루트 또는 글로벌 스킬 디렉토리에 복사
cp -r npm-reorg-guard ~/.claude/skills/
```

### 2. Claude Code 설정에 훅 추가

`.claude/settings.json` 파일에 다음을 추가합니다:

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

### 3. 필요 의존성 확인

- `jq` — JSON 파싱에 사용
- `shasum` 또는 `sha256sum` — 해시 계산에 사용
- `file` — 바이너리 탐지에 사용 (선택)

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq
```

## 로그 확인

Reorg(롤백) 이벤트는 `~/.npm-reorg-guard/reorg.log`에 기록됩니다.

```bash
cat ~/.npm-reorg-guard/reorg.log
```

스냅샷 파일은 `~/.npm-reorg-guard/snapshots/`에 저장되며, 최근 10개만 유지됩니다.
