# Verification Report - functionality-review-fixes

- Date: 2026-08-06
- Branch: `codex/functionality-review-fixes`
- Base: `19acfda2556901f8d58de45974a559f18e422f60`
- Automated result: PASS
- Real-device result: PENDING (listed in `docs/真机验收清单.md`)

## Scope

The implementation closes the functionality review findings across relay frame limits,
dialout supervision, server-initiated requests, typed approvals, reconnect/resume,
connection intent, side-chat ownership, conversation scrolling, full diff snapshots,
terminal lifecycle, and photo attachment cancellation. Root Comet gates now cover the
whole repository.

## Automated Evidence

| Gate | Command | Result | Duration |
|---|---|---:|---:|
| Build | `bash scripts/comet-build-check.sh` | PASS | ~31s |
| Full verify | `bash scripts/comet-verify-check.sh` | PASS | ~53s |
| Focused dialout | `swift test --package-path relay-dialout --filter 'LargeFrameIntegrationTests\|DialoutSupervisor\|supervisorReconnectsAfterRealRemoteClose'` | PASS | ~4s |
| Focused iOS | selected server-request, approval, resume/outbox, terminal and image suites | PASS | ~5s |
| Linux Swift 6 | `docker run ... swift:6.1 ... swift test` for three relay packages | PASS | ~5m |

Full verify counts:

- RelayProtocol: 42 passed.
- relay-server: 43 passed (2 XCTest + 41 Swift Testing).
- relay-dialout: 61 passed (6 XCTest + 55 Swift Testing).
- mac-daemon: 48 passed.
- iOS `CodexRemoteTests`: 729 passed, 0 failed, 0 skipped on iPad Pro 11-inch
  (M4), iOS Simulator 26.5. Evidence:
  `ios/DerivedData/Logs/Test/Test-CodexRemote-2026.08.06_16-32-56-+0800.xcresult`.
- `xcodebuild analyze`: PASS.
- `openspec validate functionality-review-fixes --strict`: valid.
- `git diff --check`: PASS on a clean worktree.

Linux evidence:

- Image: `swift:6.1`.
- Compiler: Swift 6.1.3 (`swift-6.1.3-RELEASE`).
- Target: `aarch64-unknown-linux-gnu`.
- RelayProtocol: 42 passed; relay-server: 43 passed; relay-dialout: 59 passed.

The first full iOS verify exposed three snapshot/layout hosts missing the newly required
`UserInputStore`, `McpElicitationStore`, and `SideChatStore` environments. Production
injection was already correct. The test hosts were fixed in `6a6161cc`, the three tests
passed in isolation, and the entire verify wrapper then passed from a clean commit.

## Residual Checks

Real iPad relay behavior, real network transitions, Stage Manager/Split View, touch and
keyboard interaction, and terminal/photo behavior under device memory pressure were not
executed in this session. They remain unchecked in the functionality-review-fixes section
of `docs/真机验收清单.md`; automated results are not used as a substitute.

`verify_result = pass` (automated gates; real-device acceptance pending)
