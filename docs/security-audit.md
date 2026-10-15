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
| AUDIT-FIND-001 | The two transports decide host-key trust differently | **implemented**; every gate below green and mutation-proven. Legacy migration landed. Not yet committed |
| AUDIT-DEF-001 | Resolver deleted the generated trust file before `ssh` read it | fixed; the convergence gate was green while this held |
| AUDIT-DEF-002 | Jump hop resolved with the target's trust file | fixed; per-hop gate mutation-proven |
| AUDIT-DEF-003 | Default resolver was the user's real trust store; tests wrote to it | fixed; parameter now required, production store named-only. Residue cleaned by hand |
| AUDIT-DEF-004 | Argv recorder really launched `ssh`; orphans wedged the machine | fixed; `recordOnly` mode |
| AUDIT-GATE-001 | `knownHostsPath(in:)` split argv on spaces, truncating quoted paths with spaces | fixed; quote-aware extractor |
| AUDIT-GATE-002 | Trust-file assertions printed real `known_hosts` contents on failure | fixed; shape-only failure messages |
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
## Defects found while closing AUDIT-FIND-001

Four defects surfaced during the remediation. Two were in the fix itself, and two
were in the gates that were supposed to be watching it — which is the part worth
recording, because in three of the four cases the gate was green while the
property was absent or untrue.

### AUDIT-DEF-001 — the generated trust file was deleted before `ssh` read it

`OpenSSHKnownHostsResolver.renderAndWrite` cleaned up its scratch directory with
`defer`, which runs on return. The caller received a path to a file that had
already been deleted. With `StrictHostKeyChecking=yes` this fails closed with
`Host key verification failed.` — **the same message ssh produces for a genuinely
substituted key.**

Consequences:

- Every resolver-resolved OpenSSH connection failed. The compatibility transport
  could not connect at all, in either direction: a correct key and an attacker's
  key produced identical outcomes.
- The AUDIT-FIND-001 convergence gate was green while the compat leg was
  rejecting for the wrong reason. It was asserting `compatRejected`, and the
  compat leg rejected — because it had no trust file to verify against.

Fixed: the resolver now returns `ResolvedKnownHostsFile`, which carries
`path` plus `temporaryDirectory`. `temporaryDirectory` is `nil` for an explicit
override, so cleanup ownership is visible in the type and a caller cannot mistake
a user-owned file for a scratch directory. `OpenSSHBackend` tracks the files it
owns and removes them in `close()`.

### AUDIT-DEF-002 — both hops were resolved with the target's trust file

Every argv path resolved the jump host with `explicitOverride:
knownHostsPathOverride` — the *target's* override, three lines below a comment
asserting that each hop gets its own record. The comment was correct and the code
was not.

Dormant in production (the override is test-only), but it is the exact bypass the
remediation exists to prevent, and it meant no jump-host gate could be written
against the override path. Fixed: the jump hop resolves with `explicitOverride:
nil` and carries an override has no meaning for a second host.

### AUDIT-DEF-003 — the default resolver was the user's real trust store

`OpenSSHBackend`'s `knownHostsResolver` defaulted to `nil`, and `nil` resolved to
`CanonicalHostKeyStore.defaultFileURL()` — `~/Library/Application Support/Bonk/host_key_records.json`.

Any construction site that omitted the parameter silently got the user's live
trust store. Two suites did. On first contact the resolver probes and CAS-writes,
so those runs **persisted test-server keys into the user's trust store**. Four
records (`127.0.0.1:25300-25303`, then `25300`/`25303` again) were written and
removed by hand; the store is now empty and the residue is archived alongside the
mutation fixtures.

Fixed: the parameter is now non-optional with no default, and the production store
is reachable only through the named
`OpenSSHKnownHostsResolver.production()`. Omitting it is a compile error rather
than a silent fallback.

### AUDIT-DEF-004 — the argv recorder also launched `ssh`

`RecordingOpenSSHProcessSpawner` recorded the argv *and* spawned the real binary.
Harmless for a direct connection, which fails fast against a fixture. Not
harmless for a jump-host argv: the inner `ssh` carries `-W %h:%p` and blocks
waiting on a forwarding channel the bench fixture does not service.

The orphans accumulated across runs, pinned PTYs, and eventually wedged the
machine badly enough that `BenchSSHServerSmokeTests` — which shares no code with
any of this — stopped completing at all. Diagnosis cost a 25-minute timeout and a
manual sweep; the suite then passed in 1.3 seconds.

Fixed: the recorder takes `recordOnly`, which records the real argv and spawns
`/usr/bin/true`. Gates that need a live connection must use the default spawner
and close their backend.

### What the gates now require

`OpenSSHTrustDecisionConvergenceTests` no longer accepts any host-key refusal. It
requires `REMOTE HOST IDENTIFICATION HAS CHANGED`, ssh's message for a key that
does not match an entry it already had. That is what separates a caught
substitution from a missing trust file, and it is the assertion whose absence let
AUDIT-DEF-001 stand behind a green suite.

`ProxyCommandPerHopTrustTests` asserts three layers, because each catches a
different regression: the outer and `ProxyCommand` trust paths differ; each file
exists and carries *its own* host's key; and the store is unchanged afterwards.
Mutation-proven — pointing the jump hop at the target's file produces two
designated reds, one per file-content assertion.

### Defect → regression gate

Each defect above was found by a gate that did not exist yet, and each is now
held by a named test plus the mutation that proves the test can fail. The
"before" column is what the suite looked like while the defect was live — it is
recorded because "the gate is green" is only meaningful next to "and here is
what it said when the property was absent".

| Defect | Regression gate | Mutation that turns it red | Before the gate existed |
|--------|-----------------|-----------------------------|-------------------------|
| DEF-001 trust file deleted before `ssh` read it | `resolverGeneratedTrustFileIsUsableAtLaunch`; `expectStrictTrustFile` (existence assertion, used by the reconnect and SFTP gates); `REMOTE HOST IDENTIFICATION HAS CHANGED` in the convergence gate | re-add the pre-return `removeItem` | convergence gate **green** while the transport could never connect |
| DEF-002 jump hop resolved with the target's trust file | `ProxyCommandPerHopTrustTests.proxyCommandCarriesItsOwnTrustFile` — three layers: paths differ, each file carries its own key, store unchanged | point the jump hop at the target's resolved file | per-hop isolation **unasserted**; the code contradicted its own comment |
| DEF-003 default resolver was the user's real trust store | non-optional `knownHostsResolver` (compile-time), `OpenSSHKnownHostsResolver.production()` as the only production call site, store-integrity assertions in the convergence and reconnect gates | — (compile error, not a runtime mutation) | four test-server keys written to `~/Library/Application Support/Bonk` |
| DEF-004 argv recorder really launched `ssh` | `RecordingOpenSSHProcessSpawner(recordOnly:)`; leak count asserted after every run in this ledger's evidence | — | orphaned `ssh -W` processes pinned PTYs and wedged unrelated suites |

Two further gate defects were found and fixed while building these, and both are
worth recording because each produced a *plausible* wrong answer:

- `knownHostsPath(in:)` split argv on spaces. Production quotes the trust path
  with `sshConfigQuote`, and Application Support contains a space, so the
  extractor returned a truncated path. The mutation run reported "missing file"
  — a true conclusion reached for a false reason, in a gate whose whole purpose
  is to distinguish false reasons. Now quote-aware.
- Two trust-file assertions embedded the file's contents in their failure
  message. A mutation run printed the user's real `known_hosts` — their actual
  host list — into the test log. Failures now report line count, byte count and
  whether the expected key was present. Size and shape diagnose the failure;
  the contents are not needed and are real trust state.

### Step 4 gate inventory

| Gate | Property | Verified by mutation |
|------|----------|---------------------|
| `OpenSSHTrustPolicyArgvTests.connectionArgvCarriesTrustPolicy` | argv carries `StrictHostKeyChecking=yes`, no `accept-new`, an app-private `UserKnownHostsFile` | restoring `accept-new` |
| `OpenSSHTrustPolicyArgvTests.auditFind001IsNotReintroduced` | the defect itself cannot return unnoticed | same |
| `OpenSSHTrustPolicyArgvTests.resolverGeneratedTrustFileIsUsableAtLaunch` | the named trust file exists and carries the canonical key | deleting it |
| `OpenSSHTrustDecisionConvergenceTests` | both transports refuse the same substituted key, and refuse it for the *substitution* reason | deleting the trust file |
| `ProxyCommandPerHopTrustTests` | each hop has its own trust file, carrying its own key; store unchanged | jump reusing the target's file |
| `ReconnectAndSFTPTrustConvergenceTests.reconnectResolvesTrustBeforeSpawning` | reconnect verifies against the canonical store and never writes to it | reconnect falling back to the legacy `known_hosts` |
| `ReconnectAndSFTPTrustConvergenceTests.sftpResolvesTrustBeforeSpawning` | the SFTP argv — built independently of the PTY argv — carries a strict trust file with the canonical key | same family |
| `ProbeClassifierProductionWiringTests` | one classifier, the production probe is what the observation suite drives, and failure classifications fail closed | weakening the production classifier |
| `LegacyHostKeyMigrationTests` | empty/valid/idempotent import; a conflict leaves **both** stores byte-identical; the legacy source is never written | making the legacy pin win a conflict |

The per-hop gate keeps all three responsibilities deliberately, and the
trust-store-integrity assertion is not optional: several of these defects were
invisible to argv assertions alone because the argv was correct and the file
behind it was not.

### Legacy digest-only entries require re-enrollment — an intentional policy

**This is a security policy, not a migration limitation, and it needs stating
plainly so nobody later reads the migration as "existing trust was preserved".**

What the migration preserves is an **inventory**: the fact that a host was pinned
before, and to which fingerprint. What it deliberately does **not** create is
**usable canonical trust**. `records` stays empty for every migrated host.

The distinction is the whole design. A SHA-256 pin is a one-way digest; it
cannot be inverted into the public key material a connection needs to be
verified without a round trip. So a migrated entry is recorded as
`legacyFingerprintOnly`, and `OpenSSHKnownHostsResolver` handles that state with
one credential-free probe:

- probe presents the live key, with no credential attached
- `ProbeOutcomeClassifier` must return `keyAcceptedAuthenticationRefused` — ssh
  positively confirming `is known and matches the … host key`, then refusing
  auth because the probe offers none
- only then does `backfillKeyMaterial` write a `records` entry
- if the presented key does not match the pin, `legacyPinMismatch` throws and
  nothing is written

**Consequence, stated for the record:** on the first connection to each of the 35
migrated hosts, the user sees a credential-free probe rather than an immediate
connection. That is the cost of not trusting a digest, and it is paid once per
host. The alternative — treating a bare digest as sufficient — would authorise a
connection on the strength of data that cannot be verified, which is precisely
the silent-downgrade shape AUDIT-FIND-001 describes.

The migration is therefore **inventory preservation plus mandatory
re-enrollment**, not trust preservation. Both halves are verified: the inventory
is carried intact (`LegacyHostKeyMigrationTests.validLegacyPinIsImported`
asserts the lookup is `legacyFingerprintOnly` and that `lookup.record == nil`),
and re-enrollment is gated by the probe and the classifier mutation.

### Legacy migration — observed on a real install

The migration ran for real during full-target validation, because a test run
launches the app and `BonkApp.init` calls `HostKeyTrustMigration.runAtLaunch()`.
Verified against the machine afterwards:

```
legacy entries (com.bonk.hostKeys, JoyLiam.Bonk.plist): 35
parseable host:port with numeric port:                  35
rejected:                                                0
carried into canonical legacyFingerprints:              35
fingerprint mismatches:                                  0
canonical records created:                               0
```

Two things worth stating plainly.

**This was not test contamination, and the effect is intended.** Unlike
AUDIT-DEF-003, where a fixture wrote loopback keys into the trust store, this
copied the user's own pre-existing pins into the canonical store's inventory
table and nothing else. Without it, every one of those 35 hosts would have been
treated as first contact on the next connection — the exact silent
re-authorisation AUDIT-FIND-001 exists to end.

**What this result is, precisely.** 35 legacy entries parsed, validated against
their stored digests with zero mismatches, all 35 retained, and zero canonical
trust records created. That is **successful legacy inventory preservation and
validation**. It is **not** the migration of 35 usable trust records into the
canonical store — no usable trust was created, and none was expected to be. See
the re-enrollment policy above; the empty `records` table is the correct
outcome, not a shortfall.

**The legacy source is untouched.** `com.bonk.hostKeys` still holds all 35
entries; `UserDefaultsLegacyHostKeySource` is read-only and the migration never
deletes. A rollback to the previous build recovers the same inventory it had
before.

`records` stayed empty. That is correct and is the whole point of the shape: a
migrated digest is not usable trust. The resolver must complete one
credential-free probe and confirm the live key matches the pin before the host
can authorise anything, and `legacyPinMismatch` refuses if it does not.

### Full-target run — NOT ACCEPTED

```
command: xcodebuild test-without-building -project Bonk.xcodeproj -scheme Bonk \
           -destination 'platform=macOS' -derivedDataPath /tmp/bonk-dd
bundle:   Test-Bonk-2026.10.15_09-14-36-+0800.xcresult
executed: 776    passed: 754    failed: 12    skipped: 10
```

Against the stated criteria — `requested == executed`, `failed == 0`,
`skipped == 0` — this run is **NOT ACCEPTED**. Both conditions fail. It is
recorded here rather than quietly re-run until it looked better.

#### B-02 E2E gate: NOT VERIFIED

`SFTPMatrixLocalTests.testServiceHostKeyMismatchDoesNotFallBack` **skipped**. Its
skip condition is `XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")` and
no server is listening on :2222. The assertion inside it has therefore never
executed on this machine. Per the rule that skipped is not executed, B-02
end-to-end is **NOT VERIFIED** here, and this run does not change that status.

#### One failure was mine, and it was a real defect

`OpenSSHTrustDecisionConvergenceTests` failed with
`bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)`. It passed in
isolation every time.

Cause: `BenchSSHServer.Instance.stop()` hands the server to a detached `Task`
and returns, so the listening socket is still open when the next phase binds the
same port with a different key. The fixture is documented as supporting exactly
that two-phase "trusted A, then presents B" pattern, so this was a fixture gap
that any such test would hit. Fixed by adding `stopAndWait()`, which awaits the
close, and using it at the restart site. 4/4 in isolation afterwards;
re-verification under full-target parallelism is the next run's job.

#### Re-run with the port fix, under full parallel load

```
command:  xcodebuild test-without-building … (same invocation)
executed: 776   passed: 754   failed: 12   skipped: 10
EADDRINUSE occurrences in the log: 0
OpenSSHTrustDecisionConvergenceTests: passed
```

The port fix held. `EADDRINUSE` appears **zero** times across 776 tests running
in parallel, and the convergence gate that failed on it in the previous run now
passes without being isolated. That is the parallel-load verification the
commit gate required; the earlier 4/4 was isolation only and would not have
sufficed.

Post-run environment checks, all clean:

```
leaked ssh/probe processes:                    0
stray bonk.legacy-migration plists:            0
canonical records:                             0
canonical legacyFingerprints (inventory):      35
```

The convergence test also remains the only place a pass could have come from a
skip: it is not gated on any fixture, and the suite reports `skipped == 0` for
itself in every run.

#### A third flake appeared, in Team code

`TeamSSHHostKeyPinningTests.secondConnectionToTheSameHostSucceeds` failed in
this run and passed in the previous one. 16/16 on three isolated runs of the
whole suite, so it is parallel-load dependent.

The mechanism is a defect in the assertion, not in the product:

```swift
#expect(learned != identityStore.pinnedTeamIdentityFingerprint() ?? learned, …)
```

`??` is `NilCoalescingPrecedence`, which binds **tighter** than `!=`, so this
parses as `learned != (pin ?? learned)`. When the team identity fingerprint has
not been written yet — a timing condition under load — the right side becomes
`learned`, and the assertion compares `learned` against itself and fails. The
failure message showing both sides equal is the tell: those are not two
colliding hashes, they are one value.

Nothing in that suite reaches the canonical store, `PersistentHostKeyStore` or
`com.bonk.hostKeys`; it runs on isolated `UserDefaults` suites. So it is not a
consequence of the migration, and it is not counted against this change.

#### Eleven failures are outside this change's blast radius — VERIFIED at baseline

An argument, not a verification. Checked against a pristine `HEAD` worktree
(`git worktree add --detach <tmp> HEAD`, built and run separately, then removed)
rather than asserted.

```
pristine HEAD, same six suites:
  PlanIntelligenceTests/secondFailureAborts, abortTrace
  BudgetRuntimeTests/loopBoundIntact, shrink, summary
  InputCriticalPathContractTests/testPassiveTabAccepts, testPassiveEnterPassesThrough
  AIChatKeyboardAndPresentationContractTests/accessModePropertiesContract
  CommandNormalizerTests/sameOperationSameKey
  FoldGateTests/throwing
                                                    = 10 failures, pre-existing
```

The eleventh, `BudgetRuntimeTests/haltTrace()`, had passed in the HEAD baseline
and failed in the full-target run. Rather than write it off as noise, it was run
repeatedly on both trees in isolation:

```
haltTrace() on this change, 5 runs:  F P P F P      (2/5 failed)
haltTrace() at pristine HEAD, 6 runs: F P F F F P    (4/6 failed)
```

Non-deterministic on both trees. The sample is far too small to rank the two
flake rates against each other, and **no such ranking is claimed**: 2/5 and 4/6
are consistent with each other and with a single underlying flake rate. What the
data does establish is the narrower claim that matters — the test fails at
pristine `HEAD`, so it cannot have been introduced here. Its appearance in the
full-target run is attributable to parallel load, not to this change.

Two of the ten look environment-dependent rather than logical:
`shortName == "完全访问"` returned `"完全"`, and `"ls -la ~/foo"` did not collapse
to `<home>/foo`. Recorded as observations; neither is in scope here.

**Net: this change introduced zero new failures.** Accounting for the
full-target run is 10 pre-existing failures + 1 pre-existing flake + 1 real
defect of mine, since fixed and re-verified in isolation.


### Step 4 gate evidence, as committed

```
xcodebuild test-without-building -project Bonk.xcodeproj -scheme Bonk \
  -destination 'platform=macOS' -derivedDataPath /tmp/bonk-dd \
  -only-testing:… (the nine Step 4 suites)

requested == executed == 43
passed 43    failed 0    skipped 0

  1  AUDIT-FIND-001 probe outcome — observation pass
  3  AUDIT-FIND-001 tier 1 — trust policy reaches ssh
  1  AUDIT-FIND-001 tier 2 — the transports converge on one trust decision
  1  AUDIT-FIND-001 — each hop resolves its own trust record
  7  AUDIT-FIND-001 — legacy trust migrates, and conflicts stay unresolved
  2  AUDIT-FIND-001 — reconnect and SFTP resolve trust like first connect
  6  AUDIT-FIND-001 — the probe calls the production classifier, and there is only one
 15  Canonical host-key store — compare-and-set
  7  known_hosts renderer — canonical record serialization
```

`requested == executed == 43` with `failed == 0` and `skipped == 0`.

Mutation ledger — each gate was run green, then deliberately broken, then
restored and re-run green, with the tree hash recorded either side:

| # | Mutation | Gate(s) that went red | Restored hash |
|---|----------|----------------------|---------------|
| A | jump hop reuses the target's trust file | `ProxyCommandPerHopTrustTests` ×2 | `e94a2f26…` |
| B | trust file deleted before `ssh` reads it | `resolverGeneratedTrustFileIsUsableAtLaunch`, convergence ×1 | `3b453627…` |
| C | reconnect falls back to the legacy `known_hosts` | `reconnectResolvesTrustBeforeSpawning` | `e94a2f26…` |
| D | production classifier stops reporting a mismatch | `ProbeOutcomeObservationTests`, `unusableTrustFileIsNotARejection` | `4a14ba4b…` |
| E | legacy pin wins a conflict | `conflictLeavesBothStoresUnchanged` ×2 | `fe23f840…` |

All six restored files verified byte-identical to the pristine copies taken
before each mutation.

### Acceptance, stated precisely

Step 4 is closed on **its own scope**. It is not a claim that the whole target
is green, and the ledger should not be read as one.

```
Step 4's nine suites        VERIFIED    43/43, 0 failed, 0 skipped,
                                         each gate mutation-proven
Full target                 NOT GREEN   12 failed, 10 skipped
  10 failures                          identical set at pristine HEAD — pre-existing
  1 flake (haltTrace)                  fails at pristine HEAD too
  1 flake (Team pinning)               Team code, isolated defaults, unreachable
                                       from this change
B-02 E2E gate               NOT VERIFIED  skipped; bench-linux absent on :2222
```

The full target cannot reach `failed == 0` while those 10 pre-existing failures
remain. They are agent planning, token budgeting, keyboard input, command
normalisation and i18n strings — none of it touched here, and folding it into
this change would have meant claiming coverage of work that was not done.

### Observation — test runs litter ~/Library/Preferences

Thousands of `com.bonk.tests.teamPin.<UUID>.plist` and `com.bonk.tests.trace.*`
files have accumulated in `~/Library/Preferences` from previous test runs. Those
suites use `UserDefaults(suiteName:)`, which creates a real plist; removing the
in-memory domain does not reliably remove the file across runs. Not a security
defect and out of scope here, but it is why a directory listing of that folder is
now a multi-thousand-line dump, and it will keep growing.
