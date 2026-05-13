#!/usr/bin/env bash
# Build script for ClaudeAlarmTerminal.
#
# Usage:
#   scripts/build.sh debug   # default; ad-hoc signed local build
#   scripts/build.sh release # Developer ID signed build (requires TEAM_ID env var)
#   scripts/build.sh archive # archive + export for notarization (Day 8 dry-run)
#
# Day 1 status: archive path is a skeleton placeholder; full sign + notarize
# dry-run is wired in Day 8 via scripts/release-dryrun.sh.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

APP_NAME="${APP_NAME:-ClaudeAlarmTerminal}"
SCHEME="${SCHEME:-ClaudeAlarmTerminal}"
DERIVED_DATA="${DERIVED_DATA:-build/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-build/export}"

regenerate_project() {
  if [[ ! -d "${APP_NAME}.xcodeproj" ]] || [[ project.yml -nt "${APP_NAME}.xcodeproj/project.pbxproj" ]]; then
    echo "[build] regenerating Xcode project from project.yml"
    xcodegen generate --quiet
  fi
}

mode="${1:-debug}"
case "${mode}" in
  debug)
    regenerate_project
    xcodebuild \
      -scheme "${SCHEME}" \
      -configuration Debug \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "${DERIVED_DATA}" \
      build
    ;;
  release)
    regenerate_project
    : "${TEAM_ID:?TEAM_ID env var is required for release builds}"
    xcodebuild \
      -scheme "${SCHEME}" \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "${DERIVED_DATA}" \
      DEVELOPMENT_TEAM="${TEAM_ID}" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      build
    ;;
  archive)
    regenerate_project
    : "${TEAM_ID:?TEAM_ID env var is required for archive builds}"
    rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}"
    xcodebuild archive \
      -scheme "${SCHEME}" \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -archivePath "${ARCHIVE_PATH}" \
      DEVELOPMENT_TEAM="${TEAM_ID}" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application"
    if [[ -f scripts/ExportOptions.plist ]]; then
      xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_DIR}" \
        -exportOptionsPlist scripts/ExportOptions.plist
    else
      echo "[build] scripts/ExportOptions.plist not found; skipping export (Day 8 deliverable)"
    fi
    ;;
  *)
    echo "Unknown mode: ${mode}" >&2
    echo "Usage: $0 [debug|release|archive]" >&2
    exit 1
    ;;
esac

echo "[build] ${mode} completed"
