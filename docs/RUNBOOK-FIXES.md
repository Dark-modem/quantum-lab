# RUNBOOK-FIXES.md — issues found while executing RUNBOOK-FA + RELEASE-READY on the real servers

Date: 2026-11-07 · By the phase-5 acceptance run (RC2 bundle). Every item was hit live.

## RELEASE-READY.md

1. **Stale binary hash table.** The RC2 entry lists `quantum-panel-linux-arm64 = 00c4b080…`, but the shipped bundle's binary hashes to `d4370aec…` (the go1.26.9 toolchain pin rebuilt the binaries after the table was written). The installer correctly refused → the runbook's copy-paste command fails. Fix: RELEASE-READY must copy the hashes from the shipped bundle's own `checksums.txt` (the signed source of truth) — or drop the table and reference checksums.txt only.

## install-panel.sh (RC2)

2. **TLS cert ownership vs the hardened unit.** The installer generates `/etc/quantum-panel/tls/server.{crt,key}` as **root:root (key 0600)** but writes a hardened unit running as the **quantum-panel** user. The panel cannot read its own key → the HTTPS listener never starts (`E-TLS-08` never even fires — `tlsHasCert()` just returns false from the unreadable dir). Fix: chown the tls dir/files to the service user at generation time.
3. **panel.json ownership, same bug.** `/etc/quantum-panel/panel.json` is written root:root 0600; the service runs as quantum-panel → it can't read credentials (fresh installs silently run with in-memory random passwords; the printed initial password doesn't work). Fix: chown after write, or generate as the service user.
4. **No restart on existing installs.** The installer wrote the new binary + unit but left the OLD already-running process alive (`systemctl is-active` true from the previous run). RUNBOOK-FA needs a `systemctl restart quantum-panel` step after install (or the installer restarts when the binary changed).
5. **TLS bind race → HTTPS silently off.** The panel's HTTPS listener gives up after ONE failed bind (`address already in use` — a co-tenant port race) and never retries; the panel keeps serving plain HTTP with no TLS. Product fix: retry the bind with backoff, or fail the unit loudly.
6. **Initial password file vs --generate-password.** With `--generate-password`, RUNBOOK-FA §2.4's `/etc/quantum-panel/initial-admin-password` was not the only artifact — verify the flow matches (we used the file, then reset via `password` CLI; both worked).

## install-agent.sh (RC2)

7. **Enroll without the base path 404s.** The agent posts `POST <server>/api/agent/enroll` at the ROOT, but the panel registers it under its random base path (`/<base>/api/agent/enroll`). RUNBOOK-FA's `--server https://IP:7443` (no base path) → 404. Fix (either): the installer reads the base path from the operator and appends it; or the panel registers a bootstrap enroll route at the root (R5-adjacent; requested in the review doc §R5 follow-ups).
8. **Self-signed cert has no IP SANs → fresh HTTPS enroll fails.** `x509: cannot validate certificate for 91.107.179.252` (no SANs at all — CN only; Go ≥1.15 ignores CN). And the enroll path does full CA verification (no TOFU). Fix: the installer must add the host IP as an IP SAN at cert generation AND install the cert into the host trust store (`update-ca-certificates`) so same-host and remote agents can verify. We worked around it by regenerating the cert with IP SANs + installing it into the trust store (documented remediation).
9. **Token single-use vs installer retry.** The installer's enroll failed once (cert issue above); our manual enroll with the SAME token then succeeded — good — but a genuinely consumed token after a partial failure leaves the operator to mint a new one mid-install. The installer should surface the exact panel error (it prints only "enrollment failed").

## RUNBOOK-FA text fixes

10. **§6 hardening emergency line references `gre-agent`** — the RC2 agent unit is `quantum-agent.service`; also the drop-in name there (`60-quantum-hardening.conf`) matches the module but is INEFFECTIVE on arvan-image hosts: `01-arvan-root-login.conf` (PasswordAuthentication yes) sorts first and sshd takes the first value. The runbook (and the module) must target a `00-` drop-in or neutralize the arvan file.
11. **§9 password reset uses argv** (`quantum-panel password "رمز-جدید"`) — violates the no-argv credential rule the project otherwise enforces. Use the no-argument form (generates + prints once).
12. **§2/§3 forget the panel base path.** The panel URL/UI/API live under a random base path (e.g. `https://IP:7443/<base>/`); §2 step 5's URL omits it. The initial password output includes the base path — the runbook should say to use THAT URL.
13. **§1 transfer rates**: the 2 MB-chunk + md5 method is correct and matches the lab's `deploy.sh`; add the germany-direct route note (the jump through a down iran host blocks germany access unnecessarily).

## RELEASE-READY / build-release.sh

14. **The RC2 agent ships without the engine-artifact key pin** — `engineArtifactPubKeyB64` empty → the FRP driver fails closed (journal: "no engine artifact signing key pinned in this build (fail closed)"). docs/ENGINE-ARTIFACTS.md says the offline builder pins it; build-release.sh does not. Fix: read the engine pub key (base64 DER SPKI) and add the ldflags pin to the agent build; rotate the key per the key ceremony.
15. **R5 upload cap conflict**: `security_headers.go` caps every request body at 1 MiB; the R5 upload allows 256 MiB → the upload is dead through the middleware. Fix: exempt the R5 upload route (or raise the cap for authenticated operator routes).

## Verified working as documented

- Bundle signature + checksum verification; `--verify-only` flows; idempotent installs.
- Panel HTTPS after the ownership fixes; WSS agent enrollment; mesh API (datacenters/servers/topology generate/tunnels/weights/forwards/push); DesiredV2 push + ack; matrix provisioning (after clearing stale chains); hardening module semantics (drop-in rendering is correct — the placement/precedence is the issue, item 10).

## Acceptance run additions (RC2, 2026-11-07)

16. **§3 enroll command omits the panel base path.** The agent posts the enroll to `<server>/api/agent/enroll` — the runbook's `--server https://IP:7443` (no base path) 404s because the panel registers the enroll under its random base path. The base path is only learnable from the initial-password output — the runbook should say: use the FULL URL printed at panel install (including `/<base>`) as `--server`. (Bootstrap-route request noted in the FRP review.)
17. **RELEASE-READY.md §"Installer commands" repeats the stale hash** (00c4b080…) — same issue as item 1; the installer refuses it. Always take the hash from the bundle's signed `checksums.txt`.
18. **Mesh matrix tunnel vs the v1 provisioning flow.** A mesh topology with a `matrix` slot starts the matrix driver against an instance that only exists after the v1 `agent-tunnels` provisioning ("no owned Matrix network"). The operator flow is: create the tunnel via Agent Tunnels (provisions tinc), THEN the mesh topology slot referencing that instance. The runbook's §4 should document the ordering (or the compiler should auto-provision).
19. **A failed provisioning leaves QMX_* iptables chains that block every retry** ("chain QMX_IN already exists; refusing to adopt it"). The teardown of the tombstoned tunnel removes them eventually, but retries in between all fail. Document the manual cleanup (`iptables -t nat -F QMX_IN; …`) or make provisioning idempotent.
20. **Instance allocation after a tombstone**: a recreated tunnel may get a different instance number (matrix2 vs matrix) — the operator must read the instance from the Agent Tunnels page and use it in the mesh slot params (we hit exactly this).
21. **The balancer's PREROUTING DNAT cannot be measured from the balancer host itself** (locally-generated traffic skips PREROUTING) nor from the node end (the asymmetric return path breaks the NAT hairpin). The split measurement source must be a real external client. The runbook's §4 weights step should note this.

## Night-window split run additions (2026-11-08)

22. **The weighted render normalizes over HEALTHY targets only** — a fail-closed/weight-0 target's buckets vanish and the modulus shrinks (70/30 configured rendered as mod 60 30/30 when matrix3's row read 30). Correct behavior for exclusions, but the operator-facing weights then do not match the kernel rule. The weights UI should show the effective (post-exclusion) split.
23. **The numgen `inc` split is connection-count granular, not weight-exact** — the observed per-target ratio (74/26) diverged from the rendered buckets. For weight-exact splits use `jhash` per-source with explicit buckets, or a user-space rotator.
24. **The sink/logger stdout goes to journald, not the redirect file** — the measurement scripts must read `journalctl -u <unit>` (the phase-5 job's row-file readout raced and lost the per-rep counts; the journal retained them).
