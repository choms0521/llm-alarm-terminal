#!/usr/bin/env bash
# Clones Ghostty at the pinned commit into vendor/ghostty.
#
# vendor/ is excluded from version control because the working tree includes
# Zig build artifacts (~hundreds of MB) and downloaded dependencies.
# Re-run this script after a fresh checkout, or after `rm -rf vendor/ghostty`.
#
# The pinned commit is recorded in scripts/GHOSTTY_PINNED_COMMIT.txt and must
# stay in sync with the build expectations recorded in docs/p1-acceptance-log.md.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="${PROJECT_ROOT}/vendor/ghostty"
GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/ghostty-org/ghostty.git}"
PINNED_FILE="${PROJECT_ROOT}/scripts/GHOSTTY_PINNED_COMMIT.txt"

if [[ ! -f "${PINNED_FILE}" ]]; then
  echo "[ghostty] ${PINNED_FILE} is missing — cannot determine pinned commit." >&2
  exit 1
fi

pinned_commit="$(tr -d '[:space:]' < "${PINNED_FILE}")"
if [[ -z "${pinned_commit}" ]]; then
  echo "[ghostty] pinned commit file is empty" >&2
  exit 1
fi

mkdir -p "${PROJECT_ROOT}/vendor"

if [[ -d "${GHOSTTY_DIR}/.git" ]]; then
  echo "[ghostty] existing clone detected; fetching pinned commit"
  git -C "${GHOSTTY_DIR}" fetch --depth=1 origin "${pinned_commit}" || \
    git -C "${GHOSTTY_DIR}" fetch origin "${pinned_commit}"
  git -C "${GHOSTTY_DIR}" checkout --detach "${pinned_commit}"
else
  if [[ -e "${GHOSTTY_DIR}" ]]; then
    echo "[ghostty] ${GHOSTTY_DIR} exists but is not a git checkout — refusing to clobber" >&2
    exit 1
  fi
  echo "[ghostty] cloning ${GHOSTTY_REPO}"
  git clone "${GHOSTTY_REPO}" "${GHOSTTY_DIR}"
  git -C "${GHOSTTY_DIR}" checkout --detach "${pinned_commit}"
fi

actual="$(git -C "${GHOSTTY_DIR}" rev-parse HEAD)"
if [[ "${actual}" != "${pinned_commit}" ]]; then
  echo "[ghostty] HEAD (${actual}) does not match pinned commit (${pinned_commit})" >&2
  exit 1
fi

echo "${actual}" > "${GHOSTTY_DIR}/PINNED_COMMIT"

echo "[ghostty] vendor/ghostty pinned at ${actual}"
echo "[ghostty] next step: scripts/build-libghostty.sh release"
