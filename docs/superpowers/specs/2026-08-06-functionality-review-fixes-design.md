---
comet_change: functionality-review-fixes
role: technical-design
canonical_spec: openspec
status: build
base_ref: 19acfda2738fb6e42517042222a1c4d55f51b876
---

# Functionality Review Fixes - Technical Design

## Outcome

This change closes the 13 functional defects found by the second whole-project
review. The canonical requirements are the OpenSpec deltas under
`openspec/changes/functionality-review-fixes/specs/`; this document fixes the
implementation boundaries, ownership rules, and verification strategy.

An interrupted predecessor was recovered intact:

- branch: `worktree-workspace-ui-review-fixes-2`
- worktree: `/Volumes/mount/codex-for-pados/.claude/worktrees/workspace-ui-review-fixes-2`
- state: 14 of 15 tasks committed, with the last accessibility trait patch still
  present as a four-file dirty diff
- useful overlap: cwd-aware full-diff caching and 120 pt near-bottom detection
- missing overlap: same-cwd refresh, stale async result rejection, streaming/card
  growth, and bottom-sentinel targeting

Because the original worktree still has a live Claude process and lock, the
change branches from its committed head and reapplies only the inspected final
patch in a new isolated worktree. Commit `19acfda2` is the resulting tested base;
the locked worktree remains untouched.

## Architecture

```text
RelayProtocol wire limits
        |                +----------------------+
        +--> relay-server| frame acceptance     |
        +--> dialout ----| decode + supervision |
        +--> iOS --------| final send validation|
                         +----------------------+

JSONRPCClient request receive
        -> ServerRequestRouter
             -> approval owner ---------> typed ApprovalStore
             -> user-input owner --------> interactive request store/UI
             -> MCP elicitation owner ---> interactive request store/UI
             -> unsupported -------------> JSON-RPC error
        -> exactly one terminal response per request id

Session context
        -> explicit connection intent
        -> one visible ConversationStore owner
        -> generation-keyed async work (diff, terminal, image selection)
        -> state changes are accepted only when their context token is current
```

## Implementation Decisions

### Shared relay frame budget

Add `RelayWireLimits.maxMessageBytes` to RelayProtocol and consume it in all
three peers. The server accumulator and dialout NIO upgrader enforce the same
1 MiB frame ceiling. `RelayTransport.send` checks the UTF-8 byte count after
encryption and JSON serialization, because image-only estimates do not bound
text or envelope overhead. An oversized local payload produces a typed,
user-presentable error before any socket write.

The test of record is a real NIO client/server upgrade path carrying a text
frame larger than 16 KiB and no larger than 1 MiB. A test that merely compares
constants is insufficient.

The existing untracked Linux `SymmetricKey: Sendable` compatibility file is
reviewed and, if correct, committed as part of this change. Its acceptance gate
is a real Linux Swift 6 build/test run.

### Supervised dialout lifecycle

Move connection-loop policy out of `relay-dialout/main.swift` into a testable
`DialoutSupervisor`. It owns reconnect attempts, cancellation, and the bridge
process lifecycle. Network errors and relay closes retry with capped exponential
backoff and jitter; a healthy handshake resets the attempt count. Trust refusal,
bridge exit, and SIGINT/SIGTERM are terminal.

The supervisor never replays application messages after reconnect. Protocol
state converges through the existing daemon resume path, avoiding duplicate
commands.

### Exhaustive server-request routing

Change the JSON-RPC server-request callback to return one of:

```swift
enum ServerRequestOutcome {
    case result(AnyCodable)
    case error(JSONRPCError)
    case deferred
}
```

A single router assigns exactly one owner to each request id. It supports:

- `item/tool/requestUserInput`, including multiple questions, option selection,
  free-form answers, cancellation, secret input, and `autoResolutionMs`;
- `mcpServer/elicitation/request`, including current URL and form variants;
- the three existing approval methods through `ApprovalStore`;
- every other generated request method through an immediate explicit error.

Tool input responses use `{answers: {questionId: {answers: [String]}}}`. MCP
responses preserve the generated `{action, content?, _meta?}` shape. Deferred
requests are fail-closed on disconnect and may never auto-accept.

### Typed approval boundary

Replace production `[String: Any]` probing with method-specific Codable DTOs
that mirror the generated protocol. Permission approvals retain
`fileSystem.entries`, each entry's access mode, and glob depth. File approvals
retain `threadId`, `turnId`, `itemId`, `startedAtMs`, `reason`, and `grantRoot`;
the UI resolves `itemId` to the authoritative `.fileChange` conversation item.
Command approvals retain reason, cwd, command actions, network context, and any
server amendment.

Malformed requests render a non-approvable protocol-error state and receive an
error response. No malformed or empty approval can expose an enabled Approve
button.

### Resume and connection intent

Only the generated `inProgress` turn status may restore `activeTurnId`.
`completed`, `interrupted`, `failed`, and unknown future values are terminal:
they clear in-flight state and allow queued work to drain.

Connection phase and user intent are separate. A session stores
`ConnectionIntent.automatic` or `.userDisconnected`. Explicit Disconnect sets
the latter before closing. Foregrounding, tab selection, and bootstrap call the
same `shouldAutoConnect` predicate; only explicit Connect or machine setup
returns the intent to automatic.

### Single ownership and stale-work rejection

- Side chat stores metadata only. The visible `ConversationView` creates the
  sole `ConversationStore`, notification subscription, and resume handler.
- Conversation scrolling retains the recovered 120 pt near-bottom rule but is
  driven by content-height growth, not item count. Streaming text, approval
  cards, and running indicators all target a permanent bottom sentinel.
- Full-diff snapshots are keyed by cwd, thread id, RPC identity, and refresh
  generation. Context changes invalidate immediately; late responses are
  discarded. Starting a full review awaits a fresh snapshot.
- Terminal execution records an exec task and generation. Natural exit clears
  running state. Terminate, disconnect, or cwd change invalidates the old
  generation so late responses cannot clear a newer process.
- Photo loading records a cancellable task and selection token. Selection,
  removal, send, or view disappearance invalidates the old token; the encoder
  checks cancellation between expensive stages.

## Verification Contract

The root Comet wrappers become repository-wide gates:

| Gate | Required coverage |
|---|---|
| Build | RelayProtocol, relay-server, relay-dialout, mac-daemon, iOS generation/build |
| Verify | Four Swift package test suites, iOS full tests, `xcodebuild analyze` |
| Protocol | OpenSpec strict validation and current generated-schema fixtures |
| Integration | real NIO large frame, reconnect, interactive request, resume/outbox |
| Platform | real Linux Swift 6 build/test for Linux-only conformance |
| Hygiene | `git diff --check`, no unrelated dirty files included |

Local macOS success does not substitute for the Linux gate. Simulator tests do
not substitute for the final device checklist covering network transitions,
keyboard/input forms, scrolling, and terminal restart.

## Change Boundaries

- Do not change encryption, pairing, trust-on-first-use, or protocol version.
- Do not implement arbitrary dynamic tool execution on iPad.
- Do not absorb unrelated UI/security review work beyond the recovered overlap.
- Do not commit the pre-existing `.gitignore`, `.worktreeinclude`, or
  `spike-3col` changes.
- At `plan-ready`, do not select isolation, execution mode, or TDD mode and do
  not begin implementation.

## Recovery Sequence

1. Resume the recovered worktree at its existing final dirty patch.
2. Complete its test/report/archive cycle and integrate its commits normally.
3. Update this document, the implementation-plan front matter, and
   `.comet.yaml` to the resulting base commit.
4. Reconcile only the overlapping Conversation/Review code and preserve the
   recovered regression tests.
5. After the user resumes build, select isolation, execution, and TDD modes and
   start at the first unchecked task.
