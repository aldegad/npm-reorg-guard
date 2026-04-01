# npm-reorg-guard

> 블록체인 reorg 개념을 npm 패키지 보안에 적용한 Claude Code 스킬

## 개념

블록체인에서 **reorg(reorganization)** 는 특정 블록 이후의 체인을 무효화하고, 이전의 안전한 상태로 되돌리는 메커니즘입니다.

`npm-reorg-guard`는 이 개념을 npm 패키지 관리에 적용합니다:

```
[confirmed 상태] → npm install → [pending snapshot] → 검증 통과 → [confirmed 상태]
       ↑                               │
       └──── 마지막 confirmed snapshot ┘
                                       └─ 검증 실패 → REORG → [confirmed 상태]
```

1. **스냅샷 (Block Checkpoint)**: `npm install` 실행 전, 현재 lock 파일의 해시와 사본을 저장하고 `_meta.json`에 `parent_snapshot_id`를 기록합니다.
2. **검증 (Block Validation)**: 설치 후, 변경된 lock 파일과 새 패키지들을 보안 규칙으로 검증합니다.
3. **확정 (Block Confirmation)**: 검증이 통과하면 해당 스냅샷 ID를 `~/.npm-reorg-guard/confirmed`에 기록해 finality를 부여합니다.
4. **리오그 (Chain Reorganization)**: 의심스러운 변경이 감지되면, 직전 pending 상태가 아니라 마지막 confirmed 스냅샷으로 자동 롤백합니다.

## 동작 방식

Claude Code의 Hook 시스템을 활용합니다.

### PreToolUse 훅 — `guard.sh`

Claude가 `npm install`, `pnpm add` 등의 명령을 실행하기 **직전**에 가로챕니다.

**하는 일:**
- 현재 `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `package.json`을 `~/.npm-reorg-guard/snapshots/`에 저장
- 각 lock 파일의 SHA-256 해시도 함께 저장 (PostToolUse에서 비교용)
- 스냅샷 메타데이터(`_meta.json`)에 타임스탬프, 프로젝트 경로, 실행 명령어, `parent_snapshot_id` 기록
- `current_snapshot_id`, `current_project_dir`, `confirmed` 상태 파일은 lock 디렉토리로 경쟁 상태를 방지하며 기록

**사전 차단하는 패턴 (block):**
| 패턴 | 이유 |
|------|------|
| `curl \| bash` 형태의 파이프 실행 | 원격 스크립트 직접 실행 |
| `npm config set ignore-scripts false` | install 스크립트 강제 활성화 |
| `--registry` 옵션이 `registry.npmjs.org`, `registry.yarnpkg.com` 외를 가리킴 | 악성 레지스트리 사용 시도 |
| `lod_sh`, `reacct`, `axois` 등 타이포스쿼팅 패턴 | 알려진 오타 악용 패키지명 |

의심 패턴이 감지되면 `{"decision": "block", ...}`을 반환해 명령 자체를 실행하지 않습니다.
`jq`가 없으면 훅은 경고를 출력하고 종료합니다.

---

### PostToolUse 훅 — `verify.sh`

`npm install` 완료 **직후** 변경 사항을 분석합니다.

**하는 일:**

1. **postinstall 스크립트 검사** (`check_postinstall_scripts`)
   - `_meta.json`보다 최신인 `node_modules/*/package.json`을 최대 50개 스캔
   - 각 패키지의 `preinstall`, `install`, `postinstall` 스크립트 내용을 분석
   - 아래 패턴 발견 시 `SUSPICIOUS=true` 플래그 설정:
     - 네트워크 접근: `curl`, `wget`, `fetch`, `http`, `socket` 등
     - 코드 실행: `eval`, `exec`, `spawn`, `child_process`, `Function()` 등
     - 민감 경로 접근: `.ssh`, `.env`, `.aws`, `credentials` 등
     - 난독화: `base64`, `atob`, `Buffer.from`, hex/unicode escape 등

2. **lock 파일 diff 검사** (`check_lockfile_diff`)
   - 스냅샷 내용과 현재 lock 파일 내용을 직접 비교해 변경 여부 확인
   - 변경된 경우 diff를 분석:
     - 공식 레지스트리(`registry.npmjs.org`, `registry.yarnpkg.com`) 외 `resolved` URL → 의심
     - `git://` 또는 `http://`(비HTTPS) resolved URL → 의심
     - 새로 추가된 `resolved` 항목이 50개 초과 → 의존성 폭발 의심

3. **네이티브 바이너리 검사** (`check_binaries`)
   - `node_modules/.bin/` 내 `_meta.json`보다 새로 생긴 파일 스캔
   - `file` 명령으로 ELF, Mach-O, 실행 가능한 바이너리 판별 → 의심

**REORG 실행 조건:**
`SUSPICIOUS=true`가 하나라도 설정되면:
- 마지막 confirmed 스냅샷에서 lock 파일들을 현재 위치로 복원 (confirmed가 없으면 현재 pending snapshot 사용)
- `package.json`도 변경된 경우 실제 해시 비교 후 복원
- `npm ci` 또는 `rm -rf node_modules && npm install`로 `node_modules`를 다시 설치해 악성 코드 잔존을 방지
- `~/.npm-reorg-guard/reorg.log`에 이벤트 기록
- Claude에게 `systemMessage`로 감지 내용과 롤백된 파일 목록 전달

이상이 없으면 해당 스냅샷을 자동으로 confirm 하고 종료합니다.
오래된 스냅샷 정리는 성공 경로와 reorg 경로 모두에서 실행되며, 최근 10개의 비확정 스냅샷만 정리하고 confirmed 체인은 보존합니다.

## 설치

### 사전 요구사항

- Claude Code (Hook 지원 버전)
- `jq` (JSON 파서)
- `shasum` 또는 `sha256sum`

### 설정 방법

1. 레포지토리를 클론합니다:

```bash
git clone https://github.com/aldegad/npm-reorg-guard.git
cp -r npm-reorg-guard ~/.claude/skills/
```

2. `.claude/settings.json`에 훅을 추가합니다:

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

3. 실행 권한 확인:

```bash
ls -la ~/.claude/skills/npm-reorg-guard/scripts/
```

## 로그 및 스냅샷

- **Reorg 로그**: `~/.npm-reorg-guard/reorg.log`
- **Confirmed snapshot**: `~/.npm-reorg-guard/confirmed`
- **스냅샷**: `~/.npm-reorg-guard/snapshots/`
- 최근 10개의 비확정 스냅샷만 자동 정리되며 confirmed 체인은 유지됩니다

```bash
# Reorg 이력 확인
cat ~/.npm-reorg-guard/reorg.log

# 마지막 confirmed snapshot 확인
cat ~/.npm-reorg-guard/confirmed

# 스냅샷 목록 확인
ls -la ~/.npm-reorg-guard/snapshots/
```

## 탐지 규칙 요약

| 카테고리 | 패턴 | 대응 |
|----------|------|------|
| 타이포스쿼팅 | 알려진 오타 패턴 | 차단 (PreToolUse) |
| 파이프 실행 | `curl \| bash` | 차단 (PreToolUse) |
| 비표준 레지스트리 | 공식 레지스트리 외 `--registry` 옵션 | 차단 (PreToolUse) |
| 악성 install 스크립트 | postinstall 내 네트워크 접근 | 리오그 (PostToolUse) |
| 코드 실행 | eval/exec in install script | 리오그 (PostToolUse) |
| 민감 경로 접근 | .ssh, .env, .aws | 리오그 (PostToolUse) |
| 난독화 코드 | base64, hex 인코딩 | 리오그 (PostToolUse) |
| 의존성 폭발 | 50개 이상 새 의존성 | 리오그 (PostToolUse) |
| 네이티브 바이너리 | node_modules 내 컴파일된 실행파일 | 리오그 (PostToolUse) |
| 비보안 URL | http:// 또는 git:// resolved URL | 리오그 (PostToolUse) |

## 라이선스

Apache License 2.0 — 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
