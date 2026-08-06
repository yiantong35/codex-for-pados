---
change: functionality-review-fixes
design-doc: docs/superpowers/specs/2026-08-06-functionality-review-fixes-design.md
base-ref: 19acfda2738fb6e42517042222a1c4d55f51b876
---

# Functionality Review Fixes Implementation Plan

> State: Comet build active with `executing-plans`, TDD, and an isolated
> worktree. The recovered UI line is integrated at `19acfda2`.

## Objective

Close all 13 functional-review findings while retaining the already-completed
work from `worktree-workspace-ui-review-fixes-2`. Each task has a RED check, a
minimal production change, a GREEN check, and its own reviewable commit.

## Global Guardrails

- Work from the integrated post-recovery base, then update all three base-ref
  fields before Task 1.
- Preserve existing user changes: `.gitignore`, `.worktreeinclude`,
  `packages/RelayProtocol/Sources/RelayProtocol/SymmetricKeySendable+Linux.swift`,
  and `spike-3col/`. The Linux file enters this change only after explicit review.
- Use generated protocol types/fixtures as the schema authority. Do not invent
  permissive dictionary fallbacks.
- Make async ownership explicit with request ids, generations, or cancellation
  tokens. A late result must prove that its owner is still current before writeback.
- No polling timers for reconnection UI, scrolling, or async cleanup.
- Run focused checks per task; run repository-wide gates only in the final phase.

## Phase 0 - Recover and Establish the Base

### Task 0.1: Finish the interrupted UI line

**Files:** recovered worktree's `ProgressCardBar.swift`,
`TouchAccessibilityTests.swift`, OpenSpec task state, and Comet report metadata.

- [x] Confirm the branch is still `worktree-workspace-ui-review-fixes-2` at
  `4fccfdf8` and its dirty diff contains only the known four files.
- [x] Review the added button accessibility trait and its explanatory test
  comment; preserve the 14 committed tasks unchanged.
- [x] Run the focused accessibility test and the full iOS suite.
- [x] Commit the final source patch as `19acfda2` on the isolated implementation
  branch. The original locked worktree and its private OpenSpec report remain
  untouched while its old Claude process is alive.
- [x] Record the new implementation base and successful focused/full iOS result.

### Task 0.2: Integrate without overwriting current work

- [x] Branch normally from the recovered committed head in a new worktree and
  apply only the inspected final patch; do not copy its whole dirty worktree.
- [x] Confirm the recovered cwd-diff and 120 pt near-bottom tests in the full suite.
- [x] Update `base-ref` here, `base_ref` in the change `.comet.yaml`, and the
  technical-design front matter to `19acfda2`.
- [ ] Re-run `openspec validate functionality-review-fixes --strict` after the
  planning artifact commit is present on the implementation branch.

## Phase 1 - Relay Contract and Dialout Availability

### Task 1.1: One wire-size limit, enforced end to end

**Files:**
`packages/RelayProtocol/Sources/RelayProtocol/RelayWireLimits.swift`,
`relay-server/Sources/RelayServerCore/FrameAccumulator.swift`, relay server
upgrader configuration, `relay-dialout` client upgrader, `RelayTransport.swift`,
`TransportError.swift`, `ImageEncoder.swift`, and focused package/iOS tests.

- [ ] RED: add a real NIO client/server upgrade test that sends a text frame
  above 16 KiB and below/equal to 1 MiB; prove current dialout closes/rejects it.
- [ ] RED: add iOS tests for final serialized frame overflow, including a large
  text-only payload and envelope overhead.
- [ ] Implement `RelayWireLimits.maxMessageBytes = 1 << 20` and replace local
  production constants/configuration with it.
- [ ] Check final UTF-8 frame bytes immediately before socket write and return a
  typed user-facing error on overflow.
- [ ] GREEN: run RelayProtocol, relay-server, relay-dialout, RelayTransport, and
  ImageEncoder focused tests.
- [ ] Commit: `fix(relay): align end-to-end message size limits`.

### Task 1.2: Make Linux compatibility real and tracked

**Files:** `SymmetricKeySendable+Linux.swift`, package manifests only if required,
and a Linux verification script/job if the repository lacks one.

- [ ] Review the existing untracked conditional conformance for correctness,
  isolation, and Swift-version guards.
- [ ] RED: reproduce the Swift 6 Linux compiler failure in a real Linux runner or
  container and retain the failing log.
- [ ] Add the smallest conditional compatibility implementation; do not weaken
  Sendable checking globally.
- [ ] GREEN: build/test RelayProtocol, relay-server, and relay-dialout on Linux.
- [ ] Commit: `fix(relay): support Swift 6 Linux sendability`.

### Task 1.3: Supervise dialout reconnects

**Files:** new `relay-dialout/Sources/RelayDialoutCore/DialoutSupervisor.swift`,
the executable `main.swift`, bridge lifecycle code, and new supervisor tests.

- [ ] RED: deterministic clock/random tests for connect failure, remote close,
  backoff cap, jitter bounds, cancellation, trust failure, and bridge exit.
- [ ] Extract one connection attempt behind an injectable connector and put the
  retry policy in `DialoutSupervisor`.
- [ ] Retain the bridge process across transient relay closes; stop and reap only
  owned processes on terminal shutdown.
- [ ] Reset attempts after a healthy handshake; never replay buffered app data.
- [ ] GREEN: run relay-dialout tests plus relay reconnect E2E.
- [ ] Commit: `fix(dialout): supervise relay reconnection lifecycle`.

## Phase 2 - Server-Initiated Requests

### Task 2.1: Establish an exhaustive response router

**Files:** `JSONRPCClient.swift`, new server-request routing/types, generated
protocol adapters, and `JSONRPCClientTests.swift`.

- [ ] RED: assert every generated server-request method receives result, error,
  or an intentionally deferred owner; assert unknown methods get an error.
- [ ] Add `ServerRequestOutcome` and central request-id ownership so only one
  terminal response can be emitted.
- [ ] Route approvals, user input, and MCP elicitation to distinct owners; return
  method-not-supported for unimplemented tool/auth/attestation methods.
- [ ] Fail pending deferred requests closed on disconnect and ignore duplicate
  completion attempts.
- [ ] GREEN: run JSONRPC client routing/cancellation/correlation tests.
- [ ] Commit: `fix(rpc): make server request handling exhaustive`.

### Task 2.2: Implement request-user-input

**Files:** new interactive request store/types/card view, conversation/root
presentation wiring, localization resources, and protocol fixture tests.

- [ ] RED: fixtures cover multiple questions, options, free-form, secret fields,
  cancellation, disconnect, and `autoResolutionMs`.
- [ ] Render one pending request at a time without blocking unrelated approvals;
  preserve each generated question id.
- [ ] Encode `{answers: {id: {answers: [...]}}}` exactly and complete the request
  id once; auto resolution follows the request policy and never guesses secrets.
- [ ] GREEN: run store, view-model, fixture, timeout, and disconnect tests.
- [ ] Commit: `feat(ipad): respond to tool user-input requests`.

### Task 2.3: Implement MCP elicitation

**Files:** the shared interactive request store/UI, MCP adapters, and new tests.

- [ ] RED: URL mode and form primitives, enum, array, object, cancel, and unknown
  schema cases.
- [ ] Render supported generated schemas with native controls and return the
  generated `{action, content?, _meta?}` response.
- [ ] Unsupported schema nodes show a non-submittable error and complete the RPC
  with an explicit error.
- [ ] GREEN: run the MCP schema matrix and router integration tests.
- [ ] Commit: `feat(ipad): handle MCP elicitation requests`.

## Phase 3 - Approval and Resume Correctness

### Task 3.1: Type the approval protocol boundary

**Files:** `ApprovalTypes.swift`, `ApprovalCoordinator.swift`,
`ApprovalStore.swift`, `ApprovalCardView.swift`, and approval tests/fixtures.

- [ ] RED: current generated fixtures for command, file, and permissions requests,
  plus malformed and missing-required-field cases.
- [ ] Decode method-specific DTOs and retain every decision-relevant field.
- [ ] Present malformed requests as protocol errors with approvals disabled and
  send an error response.
- [ ] GREEN: run ApprovalBoundaryTests and ApprovalStoreTests.
- [ ] Commit: `fix(ipad): decode approvals with current protocol types`.

### Task 3.2: Preserve informed permission/file decisions

- [ ] RED: permission entries retain read/write/deny and glob depth across
  presentation and response; file requests resolve the exact `itemId`.
- [ ] Show entry paths/access, command reason/network context, and file
  reason/grantRoot/files/diff from the authoritative conversation item.
- [ ] Cover decline, accept-for-turn, and accept-for-session responses without
  normalizing away server amendments.
- [ ] GREEN: run approval store/card and thread-item fixture tests.
- [ ] Commit: `fix(ipad): preserve approval context and file correlation`.

### Task 3.3: Treat only in-progress turns as active

**Files:** `ThreadReducer.swift`, conversation resume logic, outbox handling, and
`ThreadReducerTests.swift`.

- [ ] RED: table-test `inProgress`, `completed`, `interrupted`, `failed`, and an
  unknown future status.
- [ ] Restore active turn only for `inProgress`; all other values clear transient
  state and permit outbox drain while recording unknown-status diagnostics.
- [ ] GREEN: run reducer, resume, and outbox ordering tests.
- [ ] Commit: `fix(ipad): close terminal turns during resume`.

## Phase 4 - Session and Workspace Lifecycles

### Task 4.1: Persist explicit disconnect intent

**Files:** session model/storage, `SessionsManager.swift`, connection entry points,
and `SessionsManagerTests.swift`.

- [ ] RED: after explicit Disconnect, tab changes, bootstrap, and foreground do
  not connect; explicit Connect does; unexpected transport loss still reconnects.
- [ ] Add `ConnectionIntent` and route every auto-connect call through one
  predicate. Set intent before closing to remove the close callback race.
- [ ] GREEN: run session persistence and connection lifecycle tests.
- [ ] Commit: `fix(ipad): honor explicit disconnect intent`.

### Task 4.2: Give side chat one conversation owner

**Files:** `SideChatStore.swift`, `SideChatView.swift`, `ConversationView.swift`,
and side-chat isolation/store tests.

- [ ] RED: one visible side chat creates one notification continuation and one
  resume call; switching/closing cancels them; reselecting resumes authoritative
  history.
- [ ] Keep fork metadata in `SideChatStore`; construct and own ConversationStore
  only in the visible ConversationView lifecycle.
- [ ] GREEN: run side-chat isolation, ownership, and resume tests.
- [ ] Commit: `fix(ipad): remove duplicate side-chat conversation stores`.

### Task 4.3: Scroll on content growth to the real bottom

**Files:** `ConversationView.swift`, recovered scroll helper/tests, approval/running
indicator integration, and `ConversationScrollAnchorTests.swift`.

- [ ] RED: streaming delta, approval-card insertion/growth, and running-indicator
  changes auto-scroll only when within 120 pt; manual jump targets the sentinel.
- [ ] Preserve the recovered geometry rule, publish content-height growth, and
  centralize all auto/manual bottom actions on a stable bottom sentinel id.
- [ ] GREEN: run scroll policy tests and inspect portrait/landscape behavior.
- [ ] Commit: `fix(ipad): anchor conversation scrolling to content growth`.

### Task 4.4: Make full diff a generation-keyed snapshot

**Files:** `ReviewTabView.swift`, active-conversation review closures/state, and
recovered `ReviewFullDiffCacheTests.swift`.

- [ ] RED: same-cwd refresh changes content, thread/RPC changes clear immediately,
  and an older request completing last cannot overwrite a newer snapshot.
- [ ] Key by cwd/thread/RPC identity/generation, cancel or invalidate stale work,
  expose Refresh, and await refresh before starting a full review.
- [ ] GREEN: run recovered cache tests plus refresh/race/action consistency tests.
- [ ] Commit: `fix(ipad): invalidate stale full-diff snapshots`.

### Task 4.5: Converge terminal process state

**Files:** `TerminalSession.swift` and terminal tests.

- [ ] RED: natural exit clears running/pid and allows restart; terminate followed
  by immediate start is not cleared by the old response; disconnect/cwd switch
  invalidate the old execution.
- [ ] Store exec task and generation, gate all completions on current generation,
  and render the natural exit result once.
- [ ] GREEN: run terminal lifecycle/race tests.
- [ ] Commit: `fix(ipad): converge terminal execution lifecycle`.

### Task 4.6: Cancel stale photo encoding

**Files:** `ComposerView.swift`, `ImageEncoder.swift`, and ImageEncoder/composer
state tests.

- [ ] RED: slow selection A cannot overwrite B; removed/sent attachments reject
  late results; cancellation interrupts multi-stage encoding.
- [ ] Add an injectable loader, task handle, and UUID token. Cancel/replace on
  selection, removal, send, and disappearance; validate token before writeback.
- [ ] GREEN: run deterministic image race/cancellation tests.
- [ ] Commit: `fix(ipad): reject stale photo selection results`.

## Phase 5 - Repository Gates and Release Evidence

### Task 5.1: Expand Comet build and verify wrappers

**Files:** `scripts/comet-build-check.sh`, `scripts/comet-verify-check.sh`, and
change `.comet.yaml` if command paths change.

- [ ] Build wrapper generates/builds iOS and builds RelayProtocol, relay-server,
  relay-dialout, and mac-daemon with labeled failure sections.
- [ ] Verify wrapper runs all four package suites, full iOS tests,
  `xcodebuild analyze`, OpenSpec strict validation, and `git diff --check`.
- [ ] Keep scripts fail-fast while preserving enough section output to identify
  the failing component.
- [ ] Commit: `build: make Comet gates cover the full repository`.

### Task 5.2: Full verification and report

- [ ] Run the root build wrapper.
- [ ] Run the root verify wrapper.
- [ ] Run focused E2E for large frames, dialout reconnect, interactive requests,
  typed approvals, resume/outbox, terminal restart, and photo races.
- [ ] Run the real Linux Swift 6 gate and attach its environment/version evidence.
- [ ] Confirm no unrelated pre-existing dirty file is staged or changed.
- [ ] Write the Comet verification report with command, result, duration, and any
  unexecuted device-only check; set `verify_result` truthfully.
- [ ] Complete the real-device checklist, or leave those items explicitly pending.
- [ ] Strict-validate and archive `functionality-review-fixes` only after every
  required automated gate passes.

## Resume Point

After the model switch, first confirm Phase 0 has not changed externally. Then
select Comet isolation, execution mode, and TDD mode; update the plan metadata;
and begin with the first unchecked task. Do not skip directly to Phase 1 while
the recovered line remains unintegrated.
