# RUNBOOK — reproducing every phase-1C result

All commands run from the repo root. Prerequisites:

- `~/.ssh/config` has `qlab-iran` and `qlab-germany` (key `quantum-lab_ed25519`;
  germany via `ProxyJump qlab-iran`). No passwords anywhere.
- Local Go toolchain (builds for linux/amd64), python 3 for parsing/report.
- The sibling product checkouts `../quantum-agent`, `../quantum-panel`,
  `../quantum-protocol` (build uses their local state; nothing is modified).

## 0. One-time environment facts (2026-11-04)

- Both servers: Ubuntu 26.04, ufw inactive, sshd untouched.
- New packages installed by deploy.sh on BOTH servers: `tinc`, `iperf3`,
  `curl` (curl was already present on germany). Recorded in results/baseline.
- Iran server: 1 vCPU / 1 GB RAM. Germany: 2 vCPU / 4 GB RAM.

## 1. Baseline OS snapshot (restore reference)

```
bash scripts/capture-baseline.sh qlab-iran iran
bash scripts/capture-baseline.sh qlab-germany germany
```

Snapshots land in `results/baseline/<name>/` (packages, ufw, sshd, nft,
sysctl, units, listeners, network, authorized_keys). To restore a single
aspect manually, use the matching file; `deploy.sh --wipe` reverts sysctl
from these snapshots automatically.

## 2. Deploy panel + agents

```
bash scripts/deploy.sh            # idempotent; safe to re-run
bash scripts/deploy.sh --rollback # restore previous binary generation
bash scripts/deploy.sh --wipe     # remove everything deploy installed
```

deploy.sh builds both binaries with `GOOS=linux GOARCH=amd64 CGO_ENABLED=0`,
ships them (gzip + 2 MB chunks + md5 verify — the Iran↔Germany path drops
long transfers), installs `quantum-panel.service` on germany and
`quantum-agent.service` on both, and starts them. First run also:
installs tinc/iperf3/curl, seeds the panel credential (panel-generated
random password; only the argon2id hash lands in `/etc/gre-panel/panel.json`;
the plaintext is shown exactly once by the phase report).

## 3. Smoke test

```
bash scripts/smoke.sh
```

Steps: panel login → mint enroll tokens → enroll both agents → wait for
healthy heartbeats → create one Matrix tunnel via `POST /api/agent-tunnels`
(hub=germany, node=iran, mesh port 2097, forwarded port 5201) → wait until
`active` → verify qmx0 interfaces, mesh pings, matrix units, desired-state
acks → **panel-death test** (stop panel, verify tunnel keeps running and
carries iperf3 traffic, restart panel, measure agent reconnect time).
Writes `results/smoke-<date>.md` + `.json` (no secrets).

## 4. Overhead bench

```
bash scripts/bench/overhead.sh           # every engine adapter present
bash scripts/bench/overhead.sh matrix    # just the matrix engine
bash scripts/bench/overhead.sh none      # just the no-tunnel baseline
```

Writes `results/overhead-<date>.md` + `.json` (summary + per-rep raw rows in
`results/raw/`). Engine adapters live in `scripts/bench/engines/` — one file
per engine; add an engine by adding an adapter, nothing else changes.

## 5. Failure tests

```
bash scripts/failtests.sh                       # all four
bash scripts/failtests.sh kill-node blackhole   # selection
```

Writes `results/failtests-<date>.md` + `.json`: detection + recovery timings
for engine kill (hub, node), 10 % netem loss scoped to the mesh port, and a
full blackhole of the mesh port (SSH-safe scoping in every injection).

## 6. Tearing down

`bash scripts/deploy.sh --wipe` stops/removes units, binaries, configs
(`/etc/gre-panel`, `/etc/quantum-agent` incl. tinc instance dirs), reverts
sysctl to baseline values, and removes lab nft/tc leftovers. It deliberately
does NOT remove: tinc/iperf3/curl packages, the `quantum-lab-phase1c` SSH
key (documented in `results/baseline/KEY-INSTALL.md`), or the pre-existing
`/etc/tinc/matrix` leftovers (owner decision pending, see SERVER-CLEANUP-REPORT).
