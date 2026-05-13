#!/usr/bin/env bash
# Day 8 build + sign + notarize dry-run.
#
# Per the P1 plan §7, this is a 3-step verification — no actual Apple
# submission (that lives in P6 Release). Each step must exit 0 to count as
# pass. Step 1 (`notarytool history`) requires the keychain-profile recorded
# in scripts/GHOSTTY_PINNED_COMMIT.txt's sibling `docs/build-setup.md`; if it
# is missing the General must run `xcrun notarytool store-credentials` first.
#
# Steps:
#   1. xcrun notarytool history --keychain-profile claude-alarm-terminal-notary
#   2. xcodebuild archive + exportArchive -> build/export/ClaudeAlarmTerminal.app
#   3. codesign --verify --deep --strict + spctl --assess
#
# Acceptable spctl outcomes: "accepted" or "rejected source=Unnotarized Developer ID"
# (because actual notarization is deferred to P6).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

APP_NAME="${APP_NAME:-ClaudeAlarmTerminal}"
SCHEME="${SCHEME:-ClaudeAlarmTerminal}"
TEAM_ID="${TEAM_ID:-9ADWM2H336}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-alarm-terminal-notary}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-build/export}"
LOG_DIR="${LOG_DIR:-build/release-dryrun-logs}"

mkdir -p "${LOG_DIR}"

log() { echo "[release-dryrun] $*"; }

# Regenerate the project from project.yml if needed.
if [[ ! -d "${APP_NAME}.xcodeproj" ]] || [[ project.yml -nt "${APP_NAME}.xcodeproj/project.pbxproj" ]]; then
  log "regenerating Xcode project via xcodegen"
  xcodegen generate --quiet
fi

# Step 1 — keychain profile credential check.
log "Step 1: notarytool history (credential validation)"
step1_log="${LOG_DIR}/01-notarytool-history.log"
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >"${step1_log}" 2>&1; then
  log "Step 1 FAILED — keychain profile '${NOTARY_PROFILE}' is missing or invalid."
  log "Run: xcrun notarytool store-credentials \"${NOTARY_PROFILE}\" \\"
  log "       --apple-id <YOUR_APPLE_ID> --team-id ${TEAM_ID} --password <APP_PASSWORD>"
  log "Log written to ${step1_log}:"
  cat "${step1_log}"
  exit 1
fi
log "Step 1 PASSED"

# Step 2 — archive + export with Developer ID signing.
log "Step 2: xcodebuild archive + exportArchive"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}"
step2_archive_log="${LOG_DIR}/02-xcodebuild-archive.log"
xcodebuild archive \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  >"${step2_archive_log}" 2>&1
step2_export_log="${LOG_DIR}/02-xcodebuild-export.log"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  >"${step2_export_log}" 2>&1
if [[ ! -d "${EXPORT_DIR}/${APP_NAME}.app" ]]; then
  log "Step 2 FAILED — exported app bundle not found at ${EXPORT_DIR}/${APP_NAME}.app"
  cat "${step2_export_log}"
  exit 2
fi
log "Step 2 PASSED — ${EXPORT_DIR}/${APP_NAME}.app"

# Step 3 — codesign verify + spctl assess.
log "Step 3: codesign --verify --deep --strict + spctl --assess"
step3_verify_log="${LOG_DIR}/03-codesign-verify.log"
codesign --verify --deep --strict --verbose=2 "${EXPORT_DIR}/${APP_NAME}.app" >"${step3_verify_log}" 2>&1
step3_display_log="${LOG_DIR}/03-codesign-display.log"
codesign --display --verbose=4 "${EXPORT_DIR}/${APP_NAME}.app" >"${step3_display_log}" 2>&1 || true
step3_spctl_log="${LOG_DIR}/03-spctl-assess.log"
spctl_status=0
spctl --assess --type execute --verbose "${EXPORT_DIR}/${APP_NAME}.app" >"${step3_spctl_log}" 2>&1 || spctl_status=$?
spctl_out="$(cat "${step3_spctl_log}")"

case "${spctl_out}" in
  *"accepted"*|*"Unnotarized Developer ID"*)
    log "Step 3 PASSED — spctl: ${spctl_out}"
    ;;
  *)
    log "Step 3 FAILED — unexpected spctl output (exit=${spctl_status}):"
    echo "${spctl_out}"
    exit 3
    ;;
esac

log "ALL 3 STEPS PASSED. Logs at ${LOG_DIR}/"
