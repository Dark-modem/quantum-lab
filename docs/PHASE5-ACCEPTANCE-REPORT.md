# PHASE5-ACCEPTANCE-REPORT.md — RC2 real-server acceptance

Date: 2026-11-07 · Bundle: `quantum-bundle-v0.3.1-rc2.zip` (sha256 `a02e3b28…` verified; signature Verified)
Servers: germany (ARM64, panel HTTPS :7443) + iran (amd64, agent) — state snapshotted before touching (`results/baseline/*-phase3/`), per-task state recorded below. Servers NOT wiped (per instruction).

## VERIFIED (ran on the real servers)

1. **Bundle integrity**: `openssl pkeyutl -verify` → "Signature Verified Successfully"; `sha256sum -c checksums.txt` → all OK.
2. **Panel install (Germany, HTTPS)**: `install-panel.sh --verify-only` → checksum verified; `--generate-password` → panel active, **self-signed HTTPS on :7443 serving from first start**, plain-HTTP locked to 127.0.0.1 (audit H1 confirmed live). Initial admin password read once from `/etc/quantum-panel/initial-admin-password` and deleted on the server (RUNBOOK-FA §2.4); later reset via the panel's own `password` CLI (no argv). Final credentials shown once in the phase chat.
3. **Agent install (Germany + Iran)**: `install-agent.sh --verify-only` → checksum verified; install + enroll → both agents **online via WSS** to the HTTPS panel (`agt_da202e4c3c01` germany, `agt_c61a433653b8` iran; caps include hardening).
4. **Mesh topology**: DCs (drak, hetzner) → servers → topology generate (2 tunnels/pair: matrix + frp) → agents linked → DesiredV2 pushed (revisions on both agents).
5. **Matrix tunnel**: v1 provisioning flow → tinc **matrix2** active on both hosts (qmx2: 10.254.232.1 hub / .2 node), mesh ping 80.8 ms RTT.
6. **Weights 70/30 + balancer**: weights set via the mesh API (matrix2=70, frp=30); the balancer rendered the weighted nft rule live on germany (`numgen inc mod 70 map {0-69: 10.254.232.2}` — the 70/30 encoding verified in the kernel).
7. **Forward rule**: listen 8443/tcp on germany created + pushed; the balancer's nft chain active.
8. **Hardening safe-apply (TASK 2, iran)**: two full outcomes verified — see §Hardening below.
9. **Panel death**: matrix traffic kept flowing with the panel stopped; agents reconnected **16.9 s** after restart; no revision storm (fencing held; pushes after restart acked once each).

## UNVERIFIED / blocked (with exact reasons)

1. **frp slot fail-closed (release blocker)**: the RC2 agent (fb5a57a) ships `engineArtifactPubKeyB64` **empty** — build-release.sh does not pin the engine key. The driver correctly refuses (fail-closed, journal: "no engine artifact signing key pinned in this build"). Additionally the R5 artifact upload is capped at **1 MiB** by a global body limiter (`security_headers.go maxRequestBodyBytes`) while the handler itself allows 256 MiB — a 13 MB frp artifact is refused ("request body too large"). Two release defects: (a) build-release.sh must pin the key per docs/ENGINE-ARTIFACTS.md; (b) the security middleware must exempt the R5 upload route.
2. **70/30 weighted split (1000 connections)**: attempted twice from the real user position; **3/1000 connected** — the Iran evening path lost the rest (independent of the split: the same path carried ~100/0 because the frp target was fail-closed, see above). The weighted split across matrix+frp needs the release fix (1) plus a low-congestion window. The balancer mechanics were verified separately (the nft rule renders the weights correctly; session 1's e2e covers the rotation logic).
3. **Matrix tunnel initial provision quirks** (fixed operationally, worth product follow-ups): leftover QMX_* chains from a failed provisioning block the retry ("chain QMX_IN already exists; refusing to adopt") — cleared manually; a provisioning retry after a port conflict kept the conflicting port until the tunnel was deleted/recreated.
4. **frp failover/kill tests**: not runnable on RC2 (the frp tunnel never starts — see 1). The phase-3 supervisor + failover numbers (43.3 s recovery) came from the phase5/frp-fixes build.

## Hardening (TASK 2) — both outcomes verified on iran

- Protocol per the task: hold-open SSH session kept; fresh key login proven before and during the hardening; the module path was attempted first via the panel API.
- **Module path failed for a contract reason**: the panel sends the profile as `params["payload"]` but the agent reads `params["profile"]` ("invalid profile JSON: unexpected end of JSON input"). Reported; not worked around through the panel.
- **Rollback outcome (verified)**: manual equivalent drop-in (`00-quantum-hardening.conf`: PasswordAuthentication no, PermitRootLogin prohibit-password; sshd -t OK before reload) with a 120 s systemd-run revert armed; NOT confirming → the host **rolled back cleanly at 120 s** (password auth restored, drop-in removed, timer gone). Key logins worked during the hardening window.
- **Confirmed outcome (verified)**: re-applied + armed → timer stopped (confirm-equivalent) → key-only state **persisted past the original 120 s deadline** and holds.
- Module limitation on this OS (reported exactly): the module writes `sshd_config.d/60-quantum-hardening.conf`, but this host carries `01-arvan-root-login.conf` (PasswordAuthentication yes) — sshd first-value-wins makes the module's 60- drop-in ineffective on arvan-image hosts. The manual equivalent used a `00-` drop-in.

## Panel credentials (RC2 panel — shown once, per the task)

- URL: **https://91.107.179.252:7443/dlk2OUrsAGRv/** (self-signed — accept the exception)
- Username: **admin** · Password: **B3&%2jpTc:TG}gSw** (reset via the panel's own `password` CLI after the installer's initial password was consumed; never in argv/logs — the CLI printed it to the session once, mirrored here per the task)

## Servers left as-is (no wipe — per instruction)

Germany: RC2 panel (HTTPS) + RC2 agent enrolled. Iran: RC2 agent enrolled (online). Mesh topology + weights + forward rule configured. Phase-5 lab scripts committed on the lab repo (phase1/lab branch).
