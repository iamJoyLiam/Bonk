# Security audit ledger

Open items from the SSH host-key trust audit. This file records what has been
*established* and what remains *unfixed*. Establishing a defect is not fixing
it — every item below is live in the shipping code unless marked otherwise.

Last updated: 2026-10-09

**AUDIT-FIND-001 remediation**
```
Status:         DESIGN REVIEW COMPLETE
Implementation: NOT STARTED
AUDIT-FIND-001: ESTABLISHED / MUTATION-PROVEN / NOT FIXED
Probe classifier: UNVERIFIED — bench validation required
```
A complete design below is not a deployed security control. Nothing in the
"Remediation Design" section has been implemented, and the mechanism it depends
on most heavily is explicitly unverified.

## Status at a glance

| ID | Subject | State |
|----|---------|-------|
| AUDIT-FIND-001 | The two transports decide host-key trust differently | established, mutation-proven, **NOT FIXED**; design review complete, not implemented |
| B-02 policy | Host-key trust failure must not reach the second transport | verified, mutation-proven |
| B-02 E2E | The real production SFTP chain honours that rule | verified, mutation-proven (one step NOT VERIFIED under mutation — see below) |
| AUDIT-OBS-002 | OpenSSH SFTP fallback blocks on authentication | **observation only** — root cause and production impact undetermined |
| AUDIT-OBS-003 | No explicit re-trust / pin removal after legitimate rotation | **observation only** — not addressed by this fix |
| — | Native transport negotiates `algorithms: .all` | adjacent, independent; belongs to the P2 algorithm review |

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

## AUDIT-OBS-003 — no re-trust path after legitimate key rotation

**State: observation only. Deliberately NOT resolved by this fix.**

When a host's key legitimately rotates, Bonk refuses it — correctly — and then
offers the user nothing. On the SSH path there is no action behind a
`hostKeyMismatch`: `SessionManager.swift:470` sets
`failureReason = .hostKey` with `[RECOVERY_GATE] blocked=true` and no recovery.
The only trust-decision UI in the codebase is `TeamGuestSheet.swift:176`, which
belongs to Team guest pairing, not ordinary SSH.

There is also no pin-deletion API: `SSHHostKeyStore` has
`knownFingerprint` and `saveFingerprint`, and nothing that removes. So a user
with a rotated key is permanently locked out of that host on the SSH path, with
no in-product way forward.

Impact: this is a *usability* dead end, not a trust weakness — it fails closed.
It is recorded separately because the remediation below makes mismatches
*stricter and more common* (one key per host, per-hop records, restricted
algorithms), which makes this dead end easier to hit. It must not be resolved by
loosening the mismatch check.

Future resolution: an explicit, user-initiated re-trust action with a clear
intent, an auditable outcome, and old-pin removal only under that explicit
authorization. That action needs a store primitive the design below already
introduces (compare-and-set), so the mechanism will exist when the product
decision is made.

---

## AUDIT-FIND-001 — Remediation Design (Proposed, Not Implemented)

**Status: DESIGN REVIEW COMPLETE. Implementation: NOT STARTED.**
**AUDIT-FIND-001 remains ESTABLISHED / MUTATION-PROVEN / NOT FIXED.**

Read this section as a design proposal. Nothing here is a deployed control, and
§"UNVERIFIED" marks the one mechanism that must not be treated as sound until it
has been exercised against a real server.

### Goal

Make `SSHHostKeyStore` the single canonical trust store, and make every OpenSSH
connection verify against a `known_hosts` synthesized from that record with
strict checking. Eliminate the semantic divergence rather than papering over
one symptom of it.

### Current state

- native: `SSHHostKeyStore` → `HostKeyValidator`, compared pre-authentication
- compatibility: `StrictHostKeyChecking=accept-new` into an app-private
  `known_hosts`, with `GlobalKnownHostsFile=/dev/null`

Four production OpenSSH paths must all adopt the new contract:

| Path | Site |
|------|------|
| connect | `SSHNetworkService.swift:210` |
| reconnect / retry | `SSHNetworkService.swift:667`, `+ReconnectAttempt.swift:57` |
| jump host `ProxyCommand` (nested `/usr/bin/ssh`) | `OpenSSHBackend+Arguments.swift:136` |
| SFTP | via the three sites above |

The fourth is easy to miss: the `ProxyCommand` ssh is a separate process with
its own argv and its own `UserKnownHostsFile`, and it currently hardcodes
`accept-new`.

### Canonical record schema

One host, one port, one key. The identity set is deliberately not widened.

```
host + port -> {
    fingerprint: String      // "SHA256:..." — preserved, still the compare key
    keyType:     String      // SSH wire format of the key
    keyBlob:     Data        // exact public-key bytes
    capability:  .nativeAndOpenSSH | .openSSHOnly
}
```

`capability` is provenance, not a second store of trust. `openSSHOnly` marks a
host whose key type the native stack cannot represent — see §RSA.

### Trust flows

**1. Full record exists** — no preflight:

```
canonical record -> temp known_hosts -> strict algorithm set
                -> /usr/bin/ssh -o StrictHostKeyChecking=yes
```

**2. Fingerprint-only record (legacy migration)** — the pin exists but has no
key material, and a SHA-256 cannot be inverted:

```
ssh-keyscan (candidate keys, no credentials)
  -> fingerprint candidate, compare against existing pin
     -> mismatch: reject, write nothing
     -> match:   credential-free OpenSSH handshake, strict, verifying that
                 same key -> CAS-backfill key material
```

**3. First contact, nothing known** — unchanged product contract (silent TOFU):

```
ssh-keyscan -> temp known_hosts -> credential-free strict handshake
            -> only on success: atomic CAS of the canonical record
            -> credential-bearing connection, StrictHostKeyChecking=yes
```

**4. Explicit re-trust after rotation** — AUDIT-OBS-003. Not designed here.
Deliberately out of scope so this fix cannot be weakened to accommodate it.

### RSA: wire format is not a signature algorithm

`ssh-rsa` is the *wire format* of an RSA key. It does not imply a SHA-1
signature; RFC 8332 permits the same key blob with `rsa-sha2-256` and
`rsa-sha2-512`. `HostKeyAlgorithms` takes *signature* algorithms, so copying
`keyType` into it is wrong. Confirmed against local OpenSSH 10.3p1:

| pinned wire format | permitted signature algorithms (preference order) |
|---|---|
| `ssh-ed25519` | `ssh-ed25519` |
| `ecdsa-sha2-nistp256/384/521` | identical string |
| `ssh-rsa` | `rsa-sha2-512`, `rsa-sha2-256`, `ssh-rsa` |

This mapping needs its own table and its own tests. It is not derivable from
`keyType`.

The algorithm list must be **absolute, not appended**. Today
`OpenSSHBackend+Arguments.swift:99` unconditionally adds `+ssh-rsa` and line 108
appends per-endpoint overrides; under "restrict to the pinned key" the default
set must be replaced, and the per-endpoint path must be reduced to the pinned
type rather than adding to it.

SHA-1-signature-only hosts are an explicit compatibility exception, never a
silent downgrade.

`openSSHOnly` exists because `NIOSSHPublicKey` cannot represent an RSA host key
at all: its `BackingKey` covers ed25519, ecdsa-p256/384/521, custom and
certified — no RSA — and `grep -rlin rsa` over the NIOSSH sources returns
nothing. `readKeyExchangeECDHReplyMessage` discards an `ssh-rsa` reply before
`HostKeyValidator` sees it. So RSA key material is acquired via
`ssh-keyscan` + `/usr/bin/ssh`, never via Citadel. Extending NIOSSH with RSA was
considered and rejected as the largest-blast-radius option.

### Credential-free probe protocol

`ssh-keyscan` acquires *candidates*. It establishes nothing on its own: it is
unauthenticated plaintext KEX, so an active MITM controls what it returns. This
is why the second step exists and must not be optimised away.

```
ssh-keyscan -t <type> -T <timeout> -p <port> <host>
  -> temp known_hosts containing exactly the candidate
  -> /usr/bin/ssh with every credential path disabled
     -o StrictHostKeyChecking=yes
     -o UserKnownHostsFile=<temp>
     -o GlobalKnownHostsFile=/dev/null
     -o HostKeyAlgorithms=<pinned-only>
     -o PreferredAuthentications=none
     -o PubkeyAuthentication=no
     -o PasswordAuthentication=no
     -o KbdInteractiveAuthentication=no
     -o NumberOfPasswordPrompts=0
     -o BatchMode=yes
```

`PreferredAuthentications=none` is the load-bearing flag: it disables the
*methods*, where `BatchMode=yes` alone only suppresses prompting. A stale agent
or key could otherwise still be offered. The temp `known_hosts` binds the
candidate; it is never a second persistent trust authority.

The host key exchange completes before authentication begins (RFC 4253 §7 —
`SSH_MSG_KEX` precedes `SSH_MSG_USERAUTH_REQUEST`), which is what makes an
auth-failure outcome meaningful.

#### UNVERIFIED: the probe result classifier

`ssh` has no "host key verified" exit code. It exits non-zero both when the key
is rejected and when authentication is refused, so **exit status cannot
distinguish them**. The protocol requires this discrimination:

| Probe outcome | Meaning | Action |
|---|---|---|
| `Host key verification failed` | key rejected | reject, write nothing |
| auth-only failure (e.g. `Permission denied`) | **key accepted**, auth refused | CAS the record |
| timeout / refused / no output | nothing proven | fail closed |

Only the middle row permits a write.

This classifier is **UNVERIFIED**. It has not been exercised against a real
server; the three-way behaviour above is derived from documented semantics and
man-page reading, not from observation. It is the single mechanism the whole
design leans on, and it is also the easiest to get wrong in both directions — a
false "accepted" is a silent trust downgrade, a false "rejected" is a permanent
lockout. Its first test must run against `BenchSSHServer` and must cover all
three outcomes explicitly. Until then, no security property in this document
should be described as closed on the strength of it.

### Concurrency and durability

Store operations are compare-and-set, not setters. The current
`saveFingerprint` overwrites unconditionally, and that race is reachable today:
`SFTPMultiTCPPool` builds up to 4 concurrent connections to one host
(`poolShards`: balanced 2, accelerated 4), each calling `saveFingerprint`.

```
record(host, port, candidate, precondition) -> inserted
                                            -> alreadyMatching
                                            -> conflict          // fail closed
                                            -> persistenceFailure // fail closed
```

Backfilling key material onto a legacy fingerprint record must be a conditional
write: the blob may only be written while the fingerprint still matches what was
read. If it changed, that is a conflict and must reject.

Two guarantees on first trust:

- **Atomic.** Concurrent first contacts establishing different keys: exactly one
  CAS succeeds; the others fail closed and must not overwrite it. Actor
  serialisation is not sufficient justification on its own.
- **Durable before credentials.** If persistence fails, credential-bearing
  connection must not proceed. `PersistentHostKeyStore.save` writes
  `UserDefaults.standard` with no `synchronize()`, so "in-memory updated" is not
  "durably committed" — the durability boundary must be made explicit and
  tested, not assumed.

First trust is written after host-key verification and **before** user
authentication. A wrong password must not return a host to unpinned state, so
the record survives an authentication failure.

### Legacy app-private `known_hosts` migration

The existing `~/Library/Application Support/Bonk/known_hosts` holds real TOFU
state. Ignoring or clearing it would reclassify known hosts as first contacts.

- record consistent with the canonical store → confirm equivalent
- canonical store has fingerprint only → probe (flow 2), then backfill
- records conflict → **fail closed**; never pick a side, never overwrite

Until migration completes, legacy trust state must not be treated as absent.

### Jump-host trust

Each hop uses its own `(host, port)` record. A jump host's `ProxyCommand` ssh
must never be given the final target's pin. For multi-hop, every independent
hop is its own record.

### Acceptance criteria

Each row needs a behavioural test against the real production path, plus a
mutation demonstrating the gate fails when the property is removed.

| # | Scenario | Required behaviour | Mutation that must turn the gate red |
|---|---|---|---|
| 1 | Pinned host, server presents a different key | reject; never overwrite the pin | allow overwrite / permit the mismatch |
| 2 | Migration probe fingerprint ≠ legacy pin | reject; no trust state written | skip the comparison |
| 3 | Probe times out or is unreachable | fail closed; no write, no `accept-new` fallback | degrade to `accept-new` |
| 4 | Probe auth outcome misclassified | must not be treated as accepted | invert the classifier |
| 5 | Full record, strict verification fails | reject; no TOFU fallback | fall back to `accept-new` |
| 6 | First contact not yet persisted | not treated as trusted | persist before verification |
| 7 | Concurrent first contacts, different keys | one wins; others fail closed | unconditional overwrite |
| 8 | Temp `known_hosts` create/write fails | reject | fall back to app-private TOFU |
| 9 | Persistence failure during first trust | no credentials sent | continue anyway |
| 10 | Jump host `ProxyCommand` | strict check against the jump host's own record | reuse the target's pin / `accept-new` |
| 11 | Reconnect / retry path | same contract as connect | leave the retry path permissive |
| 12 | Legacy `known_hosts` conflicts with store | fail closed | prefer one side |
| 13 | Multi-key server offers an unpinned key | reject even if same host | accept any offered key |

Row 13 matters because the pin is one key: a server that also offers another
valid key must still be rejected if ssh negotiates the unpinned one. That is the
intended consequence of "restrict to the pinned key", and it must be tested as
such rather than treated as a bug.

### Adjacent, deliberately out of scope

The native transport connects with `algorithms: .all`
(`SSHNetworkService.swift:326`, `SFTPMultiTCPPool.swift:156`). Algorithm
negotiation is a separate question from trust divergence; fixing the latter does
not address it. It belongs to the P2 algorithm review and must not be presented
as covered by this design.

### Decided product contract

- **First contact remains silent TOFU.** No confirmation dialog is added in this
  fix; the goal is to remove the transport divergence, not to change first-connect
  UX. Recorded limitation: **silent TOFU cannot detect a MITM at first contact**,
  because no user participates in the trust decision. It must never be described
  as strong identity verification. Introducing a confirmation flow is a separate
  product and security decision.
- Established trust is never silently overwritten.

### Unresolved

- AUDIT-OBS-003 — explicit re-trust / pin removal. Needed more, not less, after
  this change.
- AUDIT-OBS-002 — OpenSSH SFTP fallback blocking on authentication.
- Probe result classifier — UNVERIFIED, above.
- Native `algorithms: .all` — P2 algorithm review.

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