# Architecture

`npm-reorg-guard` 의 내부 동작·설계 다이어그램. 사용자 설치 가이드는 `README.md`, 스킬 메타·hook 선언은 `SKILL.md` 가 SSoT.

---

## 1. The Big Picture — Blockchain Reorg 비유

```
            BLOCKCHAIN                      NPM LOCKFILE CHAIN
            ──────────                      ──────────────────

   ┌────────┐  ┌────────┐  ┌────────┐      ┌────────┐  ┌────────┐  ┌────────┐
   │ block0 │←─│ block1 │←─│ block2 │      │ snap-0 │←─│ snap-1 │←─│ snap-2 │
   │  hash  │  │ parent │  │ parent │      │  lock  │  │ parent │  │ parent │
   └────────┘  └────────┘  └────────┘      └────────┘  └────────┘  └────────┘
       │           │           │                │           │           │
    confirmed   confirmed     PoW              confirmed   confirmed   verify?
                                                                          │
                                                                  ┌───────┴───────┐
                                                                  ▼               ▼
                                                              suspicious        clean
                                                              → REORG          → CONFIRM
                                                              rollback to      become new
                                                              snap-1           baseline
```

핵심 아이디어:
- 각 `npm install` / `pnpm add` / `yarn add` / `npx` 가 **블록** 1개에 해당.
- 각 블록은 lockfile snapshot + `parent_snapshot_id` 로 직전 confirmed snapshot 을 가리킴 → **chain**.
- 새 블록이 "의심" 으로 판정되면 → **reorg** = 마지막 confirmed snapshot 으로 lockfile · `node_modules` 롤백.
- 깨끗하면 → 그 블록이 새 **confirmed baseline** 이 되어 다음 install 의 parent 가 됨.

---

## 2. Runtime Flow — Bash 한 줄이 들어왔을 때

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Claude / Codex 가 Bash 명령 실행을 요청                                       │
│  (예: npm install @jackwener/opencli)                                          │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                        ╔═══════════════════════╗
                        ║   PreToolUse  HOOK    ║
                        ║   ────────────────    ║
                        ║   scripts/guard.sh    ║
                        ╚═══════════════════════╝
                                    │
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
       ┌─────────────────┐ ┌───────────────┐ ┌─────────────────┐
       │  명령 분류기      │ │  pre-flight   │ │ lockfile        │
       │ npm/pnpm/yarn/   │ │ 차단 패턴      │ │ snapshot        │
       │ npx/dlx/eval...  │ │ ─────────     │ │ ─────────       │
       └─────────────────┘ │ • typosquat   │ │ ~/.npm-reorg-   │
                           │ • curl|bash   │ │ guard/snapshots/│
                           │ • --registry  │ │ + parent_snap_id│
                           │ • install:    │ │   (체인 연결)    │
                           │   safety off  │ │                 │
                           │ • npx remote  │ └─────────────────┘
                           │ • eval/subsh  │
                           └───────┬───────┘
                                   │
                          ┌────────┴────────┐
                          ▼                 ▼
                      매치 0 = pass      매치 = BLOCK
                          │                 │
                          ▼                 ▼
              ┌──────────────────┐  ┌──────────────────┐
              │ Bash 명령 실제 실행 │  │ exit 2 + reason   │
              │ (npm install...)  │  │ Claude 한테 차단   │
              └──────────────────┘  │ 메시지 반환         │
                          │         └──────────────────┘
                          ▼
                ╔═══════════════════════╗
                ║  PostToolUse  HOOK    ║
                ║  ────────────────     ║
                ║  scripts/verify.sh    ║
                ╚═══════════════════════╝
                          │
          ┌───────────────┼───────────────────────────────┐
          ▼               ▼                               ▼
   ┌──────────────┐ ┌───────────────────┐ ┌─────────────────────┐
   │ lockfile diff │ │ install scripts   │ │ node_modules/.bin/   │
   │ ─────────    │ │ 검사               │ │ 검사                  │
   │ • resolved   │ │ ─────────         │ │ ─────────            │
   │   URL 도메인  │ │ • 네트워크 호출    │ │ • 새 native binary    │
   │ • insecure   │ │ • 코드 실행        │ │ • 의심 패턴            │
   │   protocol   │ │ • sensitive path  │ │                      │
   │ • 비표준     │ │ • base64/hex      │ │                      │
   │   registry   │ │   난독화           │ │                      │
   │ • 50+ 새     │ │                   │ │                      │
   │   의존성 추가 │ │                   │ │                      │
   └──────┬───────┘ └─────────┬─────────┘ └──────────┬──────────┘
          │                   │                       │
          └───────────────────┼───────────────────────┘
                              ▼
                     ┌────────┴────────┐
                     ▼                 ▼
                 모두 깨끗            한 가지라도 의심
                     │                 │
                     ▼                 ▼
          ┌──────────────────┐  ┌─────────────────────────────┐
          │ CONFIRM          │  │ REORG (rollback)             │
          │ ─────────       │  │ ─────────                    │
          │ snapshot 을      │  │ • lockfile ← 마지막           │
          │ confirmed_${dir} │  │   confirmed snapshot 으로 복원 │
          │ 에 기록          │  │ • rm -rf node_modules         │
          │ (프로젝트별)      │  │ • npm install (재설치)        │
          │                  │  │ • reorg.log 에 기록           │
          │ 다음 install 의   │  │ • Claude 한테 경고             │
          │ parent 가 됨     │  └─────────────────────────────┘
          └──────────────────┘
```

핵심:
- **PreToolUse = 사전 차단** (typosquat / curl|bash / 비표준 registry — *명령이 실행되기 전에* 막음).
- **PostToolUse = 사후 검증 + 자동 reorg** (install script · lockfile diff · node_modules 검사 → 의심 시 rollback).
- 둘은 같은 `~/.npm-reorg-guard/` snapshot 저장소를 공유. PreToolUse 가 snapshot 만들고 PostToolUse 가 confirm/rollback.

---

## 3. State Layout — `~/.npm-reorg-guard/`

```
~/.npm-reorg-guard/
├── snapshots/
│   ├── 20260101-120000-abc123/
│   │   ├── package-lock.json     ← 실제 lockfile 복사본
│   │   ├── yarn.lock              ← (있으면)
│   │   ├── pnpm-lock.yaml         ← (있으면)
│   │   └── meta.json              ← parent_snapshot_id, dir_hash, command
│   ├── 20260101-130000-def456/   ← 다음 install
│   └── ...                        ← 오래된 unconfirmed 은 최근 10개만
│
├── confirmed_${dir_hash_A}        ← 프로젝트 A 의 마지막 confirmed snapshot ID
├── confirmed_${dir_hash_B}        ← 프로젝트 B 의 마지막 confirmed snapshot ID
├── confirmed_${dir_hash_C}        ← ...
│
├── locks/                         ← TOCTOU race 방지 (atomic state)
│   └── *.lock                     ← stale > 60s 자동 제거
│
└── reorg.log                      ← 모든 reorg event 기록 (append-only)
```

설계 결정 (Security Hardening):
- **Per-project confirmed state** — `confirmed_${dir_hash}` 로 프로젝트별 분리. 다른 프로젝트의 confirmed 가 침범 못 함.
- **Atomic state files** — 동시 install 시 race condition (TOCTOU) 방지.
- **Stale lock 자동 복구** — 60초 넘은 lock 은 dead 로 판단해 제거. 죽은 프로세스가 lock 남기는 케이스 방어.
- **`umask 077`** — snapshot 파일은 owner 만 읽기.
- **Path canonicalization** — `realpath` / `readlink -f` 로 traversal 공격 방지.
- **JSON-safe metadata** — `jq -Rs` 로 escape. dir 경로에 특수문자 있어도 안전.

---

## 4. Threat Model — 무엇을 막는가

```
┌──────────────────────────────────────────────────────────────────┐
│  Pre-flight (PreToolUse / guard.sh) — 명령 실행 BEFORE 차단        │
├──────────────────────────────────────────────────────────────────┤
│ • typosquat        lod_sh, reacct, axois, etc.                    │
│ • curl | bash      pipe remote execution                          │
│ • --registry       non-standard URLs                              │
│ • install scripts  safety disabled                                │
│ • eval / subshell  명령 indirection 으로 install 숨김              │
│ • npx / dlx        remote 실행 = trust boundary 넘김               │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Post-install (PostToolUse / verify.sh) — REORG 트리거             │
├──────────────────────────────────────────────────────────────────┤
│ • install script   네트워크 호출 / 코드 실행 / sensitive path 접근  │
│ • obfuscation      base64 / hex 인코딩된 페이로드                   │
│ • lockfile         resolved URL 이 비표준 registry / insecure proto │
│ • dep explosion    한 번에 50+ 새 의존성 추가 (의심)                │
│ • native binary    node_modules/.bin/ 의 새 native binary           │
└──────────────────────────────────────────────────────────────────┘
```

**막지 않는 것** (현재):
- 이미 confirmed 된 패키지 안의 zero-day 취약점.
- npm registry 자체의 손상.
- 사용자가 `KUMA_SKIP_*` / `--ignore-scripts` 같은 명시 우회 한 경우.

---

## 5. 컴포넌트 책임 분리 (SoC)

```
┌─────────────────────────────────────────────────────────────────────┐
│  SKILL.md          — 스킬 메타 + hook 선언 (Claude/Codex loader 가    │
│                      읽는 SSoT)                                       │
├─────────────────────────────────────────────────────────────────────┤
│  README.md         — 사용자 install 가이드                            │
├─────────────────────────────────────────────────────────────────────┤
│  ARCHITECTURE.md   — 내부 흐름·설계 (이 문서)                          │
├─────────────────────────────────────────────────────────────────────┤
│  scripts/guard.sh  — PreToolUse — 명령 분류 + 사전 차단 +              │
│                      lockfile snapshot                                │
├─────────────────────────────────────────────────────────────────────┤
│  scripts/verify.sh — PostToolUse — lockfile diff + install script /   │
│                      node_modules 검사 + reorg (rollback) 결정         │
└─────────────────────────────────────────────────────────────────────┘
```

각 스크립트는 **stdin 으로 hook 입력 JSON 받음** (Claude Code spec):

```json
// guard.sh 가 받는 입력 (PreToolUse)
{
  "tool_name": "Bash",
  "tool_input": { "command": "npm install foo" }
}

// verify.sh 가 받는 입력 (PostToolUse)
{
  "tool_name": "Bash",
  "tool_input": { "command": "npm install foo" },
  "tool_response": { "success": true, ... }
}
```

**출력**:
- `exit 0` = pass (다음 단계 진행).
- `exit 2` = block (Claude 에 reason 반환, 명령 실행 X).
- stdout 에 JSON 반환 시 `systemMessage` / `decision` / `hookSpecificOutput` 으로 세밀 제어 가능 (Claude Code hook spec).

---

## 6. Hook 등록 (settings.json)

`README.md` 의 install 섹션에 자세히. 핵심만:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/skills/npm-reorg-guard/scripts/guard.sh", "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/skills/npm-reorg-guard/scripts/verify.sh", "timeout": 30 }
        ]
      }
    ]
  }
}
```

`matcher: "Bash"` 라 모든 Bash 명령에 hook 이 트리거됨 — 다만 guard.sh / verify.sh 가 내부에서 npm/pnpm/yarn/npx 패턴이 아니면 **즉시 graceful skip** (exit 0). 다른 Bash 명령에 성능 영향 거의 없음.

---

## 7. 비교 — 기존 도구들과 결

| 도구 | 결 | npm-reorg-guard 와 차이 |
|---|---|---|
| `npm audit` | 알려진 CVE 매칭 | 사후 보고만, 자동 rollback X |
| `socket.dev` | static + behavioral SaaS | 클라우드 의존, 무료 quota 한도 |
| `lavamoat` | runtime sandbox | install 전 차단 X, 무거움 |
| `pnpm onlyBuiltDependencies` | install script allowlist | typosquat / curl|bash X |
| **npm-reorg-guard** | **install 전 차단 + 사후 검증 + 자동 reorg** | 단독 작동, 클라우드 0 |

설계 영감: **Blockchain reorg** 의 "잘못된 블록은 chain 에서 분기 잘라내고 마지막 안전 지점으로 복원" 개념을 npm 의 lockfile chain 에 그대로 적용.

---

## 8. 운영 로그

```bash
# 모든 reorg event 확인
cat ~/.npm-reorg-guard/reorg.log

# 현 프로젝트의 confirmed snapshot ID
DIR_HASH=$(echo -n "$(pwd)" | shasum -a 256 | awk '{print $1}')
cat ~/.npm-reorg-guard/confirmed_${DIR_HASH}

# snapshot chain 탐색
ls -lt ~/.npm-reorg-guard/snapshots/
```

---

## 9. 한계와 미래 방향

**현재 한계**:
- npm registry 자체가 손상되면 (Snyk 2018 event_stream 케이스) 우리도 못 잡음.
- 이미 confirmed 된 패키지의 zero-day 는 detection 후속 reorg 불가능.
- detection rule 이 정적 패턴 매칭 — adversarial 회피 가능.

**가능한 확장**:
- `socket.dev` / OSV.dev / GitHub Advisory 같은 외부 DB 와 cross-check.
- 의존성 트리 anomaly (갑자기 transitive dep 폭증) detection.
- 사용자 confirmed 한 snapshot 들 간의 diff visualization UI.
- multi-machine sync (여러 dev 머신에서 confirmed snapshot 공유).
