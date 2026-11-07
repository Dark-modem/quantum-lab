# PHASE5-FRP-REPORT.md — FRP fixes landed on main

Date: 2026-11-06 · Owner: phase-3/engines session (same) · Per the lead's
decision after `FRP-ENGINE-INTEGRATION-REVIEW.md` was accepted.

## VERIFIED

- **Cherry-pick series merged to `main` @ `525641910167`** (branch
  `phase5/frp-fixes`, ff-merge; only FRP files/tests touched):
  - `d502db2→5a63f46` skip directory entries in the frp artifact — the
    real GitHub tarball wraps binaries in a version dir; main's
    extraction refused it (lab-proven on the Iran agent).
  - `528db06→ba4e863` FRP role resolution via the agent's own enrollment
    name (instance fields are ambiguous — both ends see the same two
    names; the lab caught both ends running frpc).
  - `6cbeaeb→65b59c1` process supervisor — unexpected exits restart with
    capped backoff (Manager reconciles only on desired/boot; a killed
    frp process stayed dead until the next push).
  - follow-ups: capped `frpProcStop` waits (graceful-drain wedges must
    not block Stop), 60 s recovery window in the integration test
    (frpc reconnect backoff measured 43 s on the WAN), integration-test
    unmasking + a sticky-identity-seam fix in the test itself.
- **WSL Linux gate (Ubuntu 24.04, go1.23.4):** `gofmt -l` clean,
  `go vet ./...` clean, `go test ./... -count=1` ALL GREEN
  (agent 42 s, engine, hardening).
- **Real-binary integration test PASSED in WSL** (`FRP_INTEGRATION=1
  go test -tags integration`): builds frps/frpc v0.61.1 from source,
  synthetic artifact now contains a **directory entry** (production
  tarball shape), instances built in the **compiler shape** (both ends
  see the tunnel's local/remote names; roles resolve from per-end
  identities), full path verified: artifact download → verify → extract
  → spawn → tunnel → traffic → kill → Health fail → restart → traffic.
  Lab-loopback: direct 1234.5 MB/s vs via-frp 294.9 MB/s.
- New unit test: the same tunnel description resolved from both
  enrollment names → server on the frps end, client on the other;
  unrelated name → client; no identity → fail-closed error.

## UNVERIFIED

- The real-binary integration test ran **in-process in WSL**, not on the
  two lab servers (they were wiped after phase 3 and the network window
  closed mid-deploy); a WAN rerun happens with the RC2 acceptance.
- frp UDP/CPU overhead rows and the no-tunnel baseline (see
  `results/overhead-2026-11-06.md`) — reruns scripted.

## Deliverables

- Branch `phase5/frp-fixes` (pushed) → merged ff into `main`
  (`031a60b..525641910167`); remote main updated.
- `00-ADMIN/FRP-ENGINE-INTEGRATION-REVIEW.md` marked RESOLVED with the
  new main SHA.
- Superseded note: agent main has since gained the R5 engine-artifact
  manifest client (713a9f1) — desired state now carries the engine name
  only; the driver resolves pins from the panel manifest. The per-arch
  pins in params remain supported (explicit pins keep precedence).
- Hardening safe-apply exercise on the Iran server: see the phase-5
  acceptance report (in progress at writing time — the lab network
  window closed; the flow is scripted in `scripts/phase3/` follow-ups
  and will run before the RC2 acceptance).
