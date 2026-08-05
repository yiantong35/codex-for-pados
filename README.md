# CodexRemote

iPad-native SwiftUI client for controlling Codex running on a Mac over an end-to-end-encrypted relay connection.

## Repository Boundary

This repository should contain only product source, generated protocol artifacts that the app builds against, scripts, package metadata required by the checked-in project, and this environment note.

Local agent/workflow state stays out of Git: `.agents/`, `.codex/`, `.claude/`, `.codegraph/`, `.comet/`, `.omx/`, `.omc/`, `docs/`, `openspec/`, `.mcp.json`, and `skills-lock.json`.

## Environment

- Xcode 26 series.
- XcodeGen for regenerating `ios/CodexRemote.xcodeproj` from `ios/project.yml`.
- iOS/iPadOS 17 is the minimum target (`ios/project.yml` `deploymentTarget.iOS: "17.0"`).
- Use a 26-series iPad simulator named `iPad-Test` for build and verification.

## Build

```bash
cd ios
xcodegen generate
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData
```

## Verify

```bash
cd ios
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData
```

Helper wrappers:

```bash
scripts/comet-build-check.sh
scripts/comet-verify-check.sh
```
