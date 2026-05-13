# Build Setup

This document covers the one-time setup required for the local development environment, code signing, and the Day 8 notarization dry-run for ClaudeAlarmTerminal.

## Prerequisites

The development host must have:

- macOS 14.0 (Sonoma) or later, Apple Silicon
- Xcode 15 or later (verified: Xcode 26.3 / Swift 6.2.4)
- Apple Developer account with Developer ID Application certificate
- Homebrew packages: `xcodegen` (verified: 2.45.3), `zig` (required from Day 2; verified: 0.16.0)

Install xcodegen if it is not already present:

```sh
brew install xcodegen
```

## Project regeneration

The `ClaudeAlarmTerminal.xcodeproj` directory is generated from `project.yml` via xcodegen and is excluded from version control. After editing `project.yml`, regenerate with:

```sh
xcodegen generate
```

`scripts/build.sh` automatically regenerates the project when `project.yml` is newer than the existing `project.pbxproj`.

## Local debug build

```sh
scripts/build.sh debug
```

This produces an ad-hoc signed `.app` bundle under `build/DerivedData/Build/Products/Debug/ClaudeAlarmTerminal.app` that can be launched via `open` or directly from `xcodebuild`.

## Developer ID setup

The Day 8 notarization dry-run requires:

1. A Developer ID Application certificate installed in the login keychain.
2. A keychain profile that holds the Apple ID credentials used by `xcrun notarytool`.

### 1. Verify the Developer ID Application certificate

```sh
security find-identity -v -p codesigning
```

The expected output should include a line of the form:

```
9664AC2F8CA4159E0BE405D1047A185D04BF549E "Developer ID Application: minseok cho (9ADWM2H336)"
```

The Team ID `9ADWM2H336` is the identifier passed to `xcodebuild` as `DEVELOPMENT_TEAM` and to `notarytool` as `--team-id`. Export it as an environment variable so the build scripts can pick it up:

```sh
export TEAM_ID=9ADWM2H336
```

If no Developer ID Application certificate is listed, request one from the Apple Developer portal (Certificates, Identifiers & Profiles -> Certificates -> +), download the `.cer`, and double-click it to install it into the login keychain. Then re-run the `find-identity` check.

### 2. Generate an app-specific password

The notarization service does not accept the standard Apple ID password. Generate an app-specific password at <https://appleid.apple.com> under **Sign-In and Security -> App-Specific Passwords**. Label it for example `claude-alarm-terminal-notary`.

### 3. Store the credentials in a keychain profile

The Day 8 dry-run uses a keychain profile named `claude-alarm-terminal-notary`. Run this command once on the development machine:

```sh
xcrun notarytool store-credentials "claude-alarm-terminal-notary" \
  --apple-id "choms0521@gmail.com" \
  --team-id "9ADWM2H336" \
  --password "<app-specific password from step 2>"
```

`notarytool` will prompt for an interactive keychain unlock; type the login keychain password. After completion the credential will live in the login keychain under the supplied profile name.

### 4. Verify the keychain profile

```sh
xcrun notarytool history --keychain-profile claude-alarm-terminal-notary
```

A fresh setup will print `No submissions found.` which is the expected pass state for the Day 1 exit criterion. A `401`/`403` response indicates that the app-specific password is wrong; rerun step 3 with a fresh password.

## Release build (Day 8)

```sh
export TEAM_ID=9ADWM2H336
scripts/build.sh archive
```

The full 3-step notarization dry-run is wired in `scripts/release-dryrun.sh` during Day 8.

## Daily verification commands

| Command | Purpose | First passes at |
|---------|---------|-----------------|
| `xcodebuild -scheme ClaudeAlarmTerminal build` | Compiles the app from CLI | Day 1 |
| `security find-identity -v -p codesigning` | Lists Developer ID Application certificate | Day 1 |
| `xcrun notarytool history --keychain-profile claude-alarm-terminal-notary` | Validates notary credentials | Day 1 (after step 3 above) |
| `codesign --verify --deep --strict <app>` | Verifies signature integrity | Day 8 |
| `spctl --assess --type execute --verbose <app>` | Gatekeeper local assessment | Day 8 |
