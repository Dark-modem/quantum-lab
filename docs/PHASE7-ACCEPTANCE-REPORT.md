# PHASE7-ACCEPTANCE-REPORT.md — RC3 real-server acceptance

Date: 2026-11-08 · Owner: phase-5/7 session · Status: **BLOCKED — the RC3 bundle has not been announced within the polling window**; the acceptance is fully prepared and runs with one command when RC3 lands.

## 1. Poll outcome (VERIFIED)

- Polled `00-ADMIN/INTEGRATION-DONE.md` and `00-ADMIN/RELEASE-READY.md` every 60 s for **~6 h** across two poller rounds (2026-11-07 19:45 UTC → 2026-11-08 ~04:35 UTC budget consumed).
- **`FIXES: DONE` IS present** (2026-11-08): protocol `7b751ed` · panel `579d02a` · agent `822850e` · release `8ec961a` — the integration fixes are declared done.
- **No `RC3:` line exists in RELEASE-READY.md.** The release repo shows the session still working: engine packers for rathole/udp2raw/gost landed after the fixes commit — the RC3 build is in progress, not announced.
- Per the task's 6 h polling limit, the wait stopped here. The poller logic is trivial to rerun.

## 2. Fixes verified present upstream (VERIFIED, read-only)

Both blockers I reported in the RC2 acceptance are fixed on the relevant mains:
1. **R5 upload cap**: panel main exempts the engine-artifact upload from the global 1 MiB body cap (`security_headers.go`: "the global 1 MiB JSON cap must not swallow it (caught by the pack-engine end-to-end test, phase 6)").
2. **Engine-key pinning**: `quantum-release` main `8ec961a` — build-release.sh pins `engineArtifactPubKeyB64` into the agent binaries and generates the RELEASE-READY hashes **from the shipped checksums.txt** (the stale-hash-table bug cannot recur).
3. Additionally: `pack-engine.sh` (frp/rathole/udp2raw/gost) fetches upstream releases, verifies checksums, packages in the agent's extract shape with LICENSE/SOURCE, signs, and e2e-uploads through the panel (PASS).

## 3. Acceptance preparation (VERIFIED — ready to run)

- `scripts/phase7-rc3-acceptance.sh` (lab repo, committed): stages wipe → bundle-verify → panel install → agent installs → mesh (2 engines/pair) → split/flip/failover → panel-death → usage → report; reuses the phase-3/5 lab scripts (deploy.sh wipe, chunked transfer, hardening script, sink).
- Baseline snapshots for the wipe-restore: `results/baseline/*-phase3/` (the pre-RC2 state; the RC3 wipe restores the same baseline).
- The FRP artifacts (frp 0.61.1 amd64+arm64, signed, per-arch pins) are ready for the R5 upload; the panel's engine key must be the key whose pub matches the RC3 agent build pin (the release builder now injects it — verify the key pair matches before the upload).

## 4. What could not run (UNVERIFIED — blocked)

- The entire RC3 acceptance sequence: wipe → RC3 install → enroll → mesh (matrix + frp with a working frp) → weights 70/30 split (1000 conns) → weight flip → failover → panel death → hardening via the panel API (the `payload`→`profile` contract fix) → usage per direction. All UNVERIFIED for RC3 — blocked solely on the RC3 announcement.
- The RC2-era findings that RC3 is expected to resolve (carried from PHASE5-ACCEPTANCE-REPORT): the frp fail-closed key pin, the R5 upload cap, the hardening `payload`/`profile` mismatch, the `60-`/`01-` sshd drop-in precedence on arvan images.

## 5. Current server state (unchanged this phase)

- Germany: RC2 panel (HTTPS :7443, frozen ports per `ports_finalized`) + RC2 agent — active. The human's PasarGuard node untouched.
- Iran: RC2 agent — active. Both hosts reachable (Iran recovered from the ~6 h outage).
- The rotated panel credentials (verified working): admin / `x$7Rhu7|6*CCw^T)` at `https://91.107.179.252:7443/FnPDsPsVlW2l/` — shown once in the phase-5 final message; re-shown in the phase-5/7 continuation chat after the rotation.

## 6. Next actions (for the lead)

1. Announce RC3 in RELEASE-READY.md (`RC3: <path> <sha> protocol … panel … agent …`).
2. Say the word — the acceptance runs from `scripts/phase7-rc3-acceptance.sh` (or a follow-up session) and completes the VERIFIED matrix above.
