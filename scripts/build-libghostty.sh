#!/usr/bin/env bash
# Builds libghostty as an Apple universal XCFramework.
#
# The Ghostty project itself produces `macos/GhosttyKit.xcframework` via its
# `zig build -Demit-xcframework=true` target. This script wraps that flow and
# copies the framework into `Frameworks/` so the host Xcode project can link
# against it without referring into vendor/ paths.
#
# Requirements:
#   * Zig 0.15.2 (matches vendor/ghostty/build.zig.zon `minimum_zig_version`).
#     The Homebrew formula `zig@0.15` provides this version as a keg-only
#     install at /opt/homebrew/Cellar/zig@0.15/0.15.2/bin/zig.
#   * Xcode command-line tools (xcodebuild is invoked by the xcframework step).
#
# Usage:
#   scripts/build-libghostty.sh            # ReleaseFast build, universal
#   scripts/build-libghostty.sh debug      # Debug build
#   ZIG=/path/to/zig scripts/build-libghostty.sh   # override zig binary

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="${PROJECT_ROOT}/vendor/ghostty"
FRAMEWORK_OUT="${PROJECT_ROOT}/Frameworks/GhosttyKit.xcframework"

if [[ ! -d "${GHOSTTY_DIR}" ]]; then
  echo "[libghostty] vendor/ghostty is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

mode="${1:-release}"
case "${mode}" in
  release) optimize="ReleaseFast" ;;
  debug)   optimize="Debug" ;;
  *)
    echo "Usage: $0 [release|debug]" >&2
    exit 1
    ;;
esac

ZIG="${ZIG:-}"
if [[ -z "${ZIG}" ]]; then
  if [[ -x /opt/homebrew/Cellar/zig@0.15/0.15.2/bin/zig ]]; then
    ZIG=/opt/homebrew/Cellar/zig@0.15/0.15.2/bin/zig
  elif command -v zig >/dev/null 2>&1; then
    ZIG="$(command -v zig)"
  else
    echo "[libghostty] Could not locate zig 0.15.x. Install via 'brew install zig@0.15' or set the ZIG env var." >&2
    exit 1
  fi
fi

zig_version="$("${ZIG}" version)"
echo "[libghostty] using zig ${zig_version} at ${ZIG}"

if [[ "${zig_version}" != 0.15.* ]]; then
  echo "[libghostty] WARNING: zig ${zig_version} may not match Ghostty's minimum_zig_version (0.15.2)" >&2
fi

pinned_commit="$(cat "${GHOSTTY_DIR}/PINNED_COMMIT" 2>/dev/null || true)"
current_commit="$(git -C "${GHOSTTY_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "${pinned_commit}" && "${pinned_commit}" != "${current_commit}" ]]; then
  echo "[libghostty] WARNING: vendor/ghostty HEAD (${current_commit}) differs from PINNED_COMMIT (${pinned_commit})" >&2
fi

echo "[libghostty] building xcframework in vendor/ghostty (optimize=${optimize})"
(
  cd "${GHOSTTY_DIR}"
  "${ZIG}" build \
    -Demit-xcframework=true \
    -Doptimize="${optimize}"
)

src_framework="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
if [[ ! -d "${src_framework}" ]]; then
  echo "[libghostty] expected ${src_framework} after zig build, but it is missing" >&2
  exit 1
fi

mkdir -p "${PROJECT_ROOT}/Frameworks"
rm -rf "${FRAMEWORK_OUT}"
cp -R "${src_framework}" "${FRAMEWORK_OUT}"
echo "[libghostty] copied to ${FRAMEWORK_OUT}"

echo "[libghostty] done"
