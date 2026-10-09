# Security audit ledger

Open items from the SSH host-key trust audit. This file records what has been
*established* and what remains *unfixed*. Establishing a defect is not fixing
it — every item below is live in the shipping code unless marked otherwise.

Last updated: 2026-10-09

## Status at a glance

| ID | Subject | State |
|----|---------|-------|
| AUDIT-FIND-001 | The two transports decide host-key trust differently | established, mutation-proven, **NOT FIXED** |
| B-02 policy | Host-key trust failure must not reach the second transport | verified, mutation-proven |
| B-02 E2E | The real production SFTP chain honours that rule | verified, mutation-proven (one step NOT VERIFIED under mutation — see below) |
| AUDIT-OBS-002 | OpenSSH SFTP fallback blocks on authentication | **observation only** — root cause and production impact undetermined |

---

## AUDIT-FIND-001 — transports disagree about host-key trust

**State: established, mutation-proven, NOT FIXED. No trust policy is changed.**

Bonk has two SSH transports with two *independent* host-key trust stores:

- native (Citadel) — `SSHHostKeyStore`, pinned fingerprint compared inside
  `HostKeyValidator` during the handshake, before authentication
- compatibility (`/usr/bin/ssh`) — `known_hosts` file, `StrictHostKeyChecking=accept-new`

Given one server on one port, with Bonk pinned to key A while the server
presents key B:

```
native         -> REJECT   (A != B, decided pre-auth)
compatibility  -> ACCEPT   (accept-new has never seen B, and records it)
```

Both legs were offered the same key: the fingerprint the native leg rejects is
byte-identical to the one the compatibility leg writes. So selecting the
compatibility transport silently changes Bonk's host-key trust semantics — a
key change the native path refuses becomes a key the other path persists as
trusted.

**Evidence** (`BonkTests/OpenSSHTrustDecisionDivergenceTests.swift`):

| Phase | requested/executed/failed/skipped |
|-------|-----------------------------------|
| baseline  | 1/1/0/0 |
| mutation  | 1/0/1/0 — designated assertion only |
| restored  | 1/1/0/0 |

The mutation changed one production line, `StrictHostKeyChecking=accept-new` to
`=yes`, in `OpenSSHBackend+Arguments.swift`. The red came from the designated
compatibility-accept assertion, caused by ssh's own typed rejection
(`hostKey: Host key verification failed.`) rather than a timeout or a connection
error.

**Not yet decided:** how to unify the two transports' trust semantics. Every
option has a real cost, so this needs its own analysis before code changes.

Commits: `a7d8a398` (tier 1, launch boundary), `889325e` (tier 2, the decision).

---

## B-02 — a host-key failure must not reach the second transport

**State: verified, mutation-proven. The production defect it protects against is
AUDIT-FIND-001 and remains unfixed.**

When the native leg rejects a host key, the service must not retry on OpenSSH.
That retry would not re-run the check: OpenSSH consults a store that has never
seen this host, `accept-new` accepts the key Citadel just rejected, and the
attacker's key is persisted as trusted.

Two gates, because they protect different things:

- **policy** — `SFTPBackendFallbackTests` drives `SFTPBackendFallback.run` with
  observable legs. Pure predicate, mutation-proven. Correct while the
  orchestration around it is wrong is possible.
- **E2E** — `SFTPHostKeyFallbackE2ETests` drives the real chain:
  `SFTPService.connect(using:)` → `SFTPBackendFallback.run` →
  `connectCitadelLeg` → `SSHNetworkService.openSFTPClient()` →
  `makeNativeClient` → `HostKeyValidator`.

AUDIT-FIND-001 is what makes the E2E gate necessary: it establishes that the two
transports really do accept and reject different keys, so an orchestration
regression would have a concrete, demonstrated consequence.

**Evidence:**

| Phase | requested/executed/failed/skipped |
|-------|-----------------------------------|
| baseline  | 2/2/0/0 |
| mutation  | 2/1/1/0 — exactly one red |
| restored  | 2/2/0/0 |
| adjacent suites | 15/15 passed, 0 skipped |

The mutation made `permitsFallback` return `true` for host-key failures. The
single red was the designated assertion `fallbackStore.isEmpty`, and the
isolated temp `known_hosts` gained an entry for the *same* fingerprint the
native leg had just rejected. The real fallback path persisted untrusted trust
state; that is the violation, observed rather than simulated.

The designated assertion is the trust-store side effect rather than "did
`connect` throw?" because `SFTPBackendFallback.run` deliberately rethrows the
*original* error when the fallback leg itself fails, so a throw-based assertion
stays green while the key is being written underneath it.

**Trust-error delivery is NOT VERIFIED under mutation.** When the fallback leg
is permitted it blocks on authentication and `connect` never returns, so that
contract step could not be observed. It is recorded in the gate's trace rather
than asserted, and the no-fallback gate detects the persisted trust-state
violation independently. At baseline the step is verified:
`delivered=SSHServiceError.hostKeyMismatch`.

**Isolation:** `SSHNetworkService.openSSHKnownHostsPathOverride` is a
default-nil test seam. The real
`~/Library/Application Support/Bonk/known_hosts` was SHA-256 identical before
the mutation, after the mutation, and at the end of the run.

The older `SFTPMatrixLocalTests.testServiceHostKeyMismatchDoesNotFallBack`
covers the same rule but is gated on `tcpOpen(port: 2222)` and has therefore
never executed. The `BenchSSHServer`-backed suite supersedes it as runnable
evidence.

Commit: `53af20b`.

---

## AUDIT-OBS-002 — OpenSSH SFTP fallback blocks on authentication

**State: observation only. Not a confirmed defect, not a vulnerability, and not
part of B-02.**

> Under a password-authenticated `BenchSSHServer`, the OpenSSH SFTP fallback
> accepts and records the host key and then blocks at the authentication stage.
> Root cause and production impact are undetermined.

Observed during the B-02 mutation run, which was the first time the SFTP
fallback leg was ever allowed to run this far: AUDIT-FIND-001 tier 2 exercised
the compatibility *PTY* leg, and host keys are recorded pre-authentication, so
the tier 2 gate never required authentication to succeed.

What is established:

- the fallback leg is genuinely entered and does write the host key
- subsequent SFTP work stops at password authentication
- `OpenSSHBackend.runSFTP`'s 120s readiness deadline does not cover this,
  because it is only consulted once a chunk arrives, and a leg blocked on its
  password prompt produces none

What is **not** established, and must not be asserted:

- that every production SFTP fallback is unable to authenticate
- that this is reachable in production, or under which configurations
- any root cause

This needs its own investigation before it becomes a finding.

---

## Test infrastructure audit

Two harness defects surfaced while building the B-02 gate. Both change whether a
future test failure can be *observed*, and neither changes any production
behaviour or the evidence above.

### `SSHNetworkService.withThrowingTimeout` is not a hang guard

It uses `withThrowingTaskGroup`, whose body cannot return until every child task
has completed. Cancelling the loser therefore does not release the caller: the
winner may report a timeout while the run stays wedged behind a child blocked in
a read that ignores cancellation. A mutation run using it hung for an entire
test session.

It bounds the *returned value*, not the *run*. `SFTPHostKeyFallbackE2ETests`
uses a local `withHardDeadline` (unstructured worker, caller-observed deadline)
instead. Anything relying on `withThrowingTimeout` as a stall guard should be
re-examined.

### `OpenSSHBackend.runSFTP`'s readiness deadline misses silent stalls

```swift
while !Self.sftpPromptAppeared(readyBuffer) {
    if Date() > readyDeadline { throw ... }
    guard let chunk = await streamIterator.next() else { break }
    ...
}
```

The deadline is checked only after a chunk arrives, so a process that goes quiet
never reaches the check. See AUDIT-OBS-002, where this is why a blocked
authentication is not bounded in production either.