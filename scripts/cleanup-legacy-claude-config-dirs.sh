#!/usr/bin/env bash
# scripts/cleanup-legacy-claude-config-dirs.sh
#
# P3.5 REQ-3 — CLAUDE_CONFIG_DIR 격리 폐지 후 잔존 격리 디렉터리 1회용 정리.
#
# P2 의 SessionSpawnEnv.claudeConfigDir(forSession:) 는 세션마다 독립된
# claude config 디렉터리를 다음 위치에 생성했었다:
#
#   ~/Library/Application Support/ClaudeAlarmTerminal/claude-config/<UUID>/
#
# REQ-3 으로 사용자 ~/.claude 공유로 전환됐으므로, 위 디렉터리는 더 이상
# 생성되지 않는다. 본 스크립트는 잔존 디렉터리를 1회 제거한다.
#
# 사용자 자료 보호 원칙:
#   - UUID 형식 이름 디렉터리만 삭제 (다른 파일/디렉터리는 건드리지 않음)
#   - mtime 7일 이상인 디렉터리만 삭제 (최근 사용 자료 보호)
#   - dry-run 모드를 default 로 제공 (실제 삭제는 --apply 명시)
#
# 사용 예:
#   ./scripts/cleanup-legacy-claude-config-dirs.sh            # dry-run (목록 표시)
#   ./scripts/cleanup-legacy-claude-config-dirs.sh --apply    # 실제 삭제 수행
#   ./scripts/cleanup-legacy-claude-config-dirs.sh --apply --all  # mtime 무관 모두 삭제

set -euo pipefail

ROOT="$HOME/Library/Application Support/ClaudeAlarmTerminal/claude-config"
UUID_REGEX='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

APPLY=0
ALL=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --all) ALL=1 ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$ROOT" ]]; then
    echo "[cleanup] claude-config root 부재: $ROOT — 정리 대상 없음."
    exit 0
fi

# mtime threshold: 7일 (--all 면 무한대 → 모두 대상)
if [[ $ALL -eq 1 ]]; then
    MTIME_ARG=""
else
    MTIME_ARG="-mtime +7"
fi

CANDIDATES=()
while IFS= read -r entry; do
    name="$(basename "$entry")"
    if [[ "$name" =~ $UUID_REGEX ]]; then
        CANDIDATES+=("$entry")
    fi
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d $MTIME_ARG 2>/dev/null)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "[cleanup] 삭제 대상 0건. (root=$ROOT)"
    # 빈 root 디렉터리도 제거 (격리 폐지 후 보존 가치 없음)
    if [[ $APPLY -eq 1 ]]; then
        rmdir "$ROOT" 2>/dev/null && echo "[cleanup] 빈 root 디렉터리 제거: $ROOT" || true
    fi
    exit 0
fi

echo "[cleanup] 삭제 후보 ${#CANDIDATES[@]}건:"
for entry in "${CANDIDATES[@]}"; do
    echo "  - $entry"
done

if [[ $APPLY -eq 0 ]]; then
    echo
    echo "[cleanup] dry-run 모드. 실제 삭제하려면 --apply 옵션을 추가하옵소서."
    exit 0
fi

DELETED=0
for entry in "${CANDIDATES[@]}"; do
    if rm -rf "$entry"; then
        DELETED=$((DELETED + 1))
    else
        echo "[cleanup] 삭제 실패: $entry" >&2
    fi
done

echo "[cleanup] ${DELETED}건 삭제 완료."

# 모두 비었으면 root 도 제거
if [[ -d "$ROOT" ]] && [[ -z "$(ls -A "$ROOT")" ]]; then
    rmdir "$ROOT" && echo "[cleanup] 빈 root 디렉터리 제거: $ROOT"
fi
