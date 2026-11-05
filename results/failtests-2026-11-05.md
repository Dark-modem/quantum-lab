# Failure tests — 2026-11-05

Raw JSON row file was lost to a report-generation bug (fixed in
`scripts/failtests.sh`); these numbers are transcribed from the run log
(`out/failtests-run1.log`), which contains the same measurements. Mesh was
healthy before and after every test (verified post-run: mesh up, baseline
fq qdisc restored, matrix unit active).

Environment: Iran↔Germany path in evening-congestion regime (~21:00 Tehran:
high loss on the public path). Detection/recovery numbers therefore include
tinc's own reconnect handshake over a lossy path — they are NOT pure
process-restart times.

## kill-hub — SIGKILL tincd on the hub (germany)

- systemd unit `quantum-matrix.service` uses `Restart=on-failure`,
  `RestartSec=3` — the engine process restarts automatically.
- Inner-ping failure first observed: **74.3 s** after the kill
  (mesh keepalives + tinc re-handshake masked the outage window; the restart
  itself completes in ~3 s, but data-plane recovery through the congested
  path took the rest).
- Recovery: mesh restored and passing traffic by test end; the fast
  systemd restart meant the 2 s-poll loop never saw a clean
  fail→recover boundary, so no separate recovery number is claimed.

## kill-node — SIGKILL tincd on the node (iran)

- Inner-ping failure first observed: **33.3 s** after the kill.
- Same caveat as above; systemd auto-restart recovered the engine.

## netem10 — 10 % loss scoped to the mesh port (tc netem, iran egress)

- Observed inner-ping loss during injection: **17/40 lost (42.5 % observed
  at the ICMP level; netem 10 % + path loss compound)** — see note below.
- RTT during injection: **134.8 ms mean, 422 ms max** (baseline ~82 ms).
- qdisc removed cleanly; post-removal pings 2/10 OK — that residual is the
  evening path loss, not netem (qdisc verified removed; `fq` restored).

Note: 10 % netem loss on UDP mesh traffic compounds with tinc's behavior
(retries, TCP meta fallback), so inner ICMP loss > the injected 10 % is
expected on an already-lossy evening path. A daytime rerun would isolate
the two effects better.

## blackhole — 100 % loss on the mesh port (tc netem loss 100%, both directions)

- Inner-ping failure first observed: **29.9 s** after injection.
- Manual recovery (qdisc removal) at +40 s; the post-removal recovery was
  not captured cleanly (tinc re-handshake through the congested path took
  longer than the remaining observation window — mesh verified healthy
  minutes later).
- SSH control access was unaffected throughout (port-scoped injection),
  as designed.

## Product observations

- The agent's own tunnel-health reporting did not flip within the polling
  granularity in any test — worth a product follow-up: health checks that
  notice a dead mesh faster than ~30 s would improve the panel's view.
- `Restart=on-failure` + `RestartSec=3` recovers the engine process itself
  quickly; the dominant recovery cost is tinc's re-handshake over the WAN.
