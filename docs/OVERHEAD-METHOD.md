# How traffic overhead is measured (plain language)

When a user's traffic crosses a Quantum tunnel, the carrier (the public
Internet link between the Iran server and the foreign server) carries more
bytes than the user actually sent: tunnel framing, encryption, and the
TCP/IP headers of both the inner and the outer packet. The product's own
billing rule needs exactly that ratio — `wire bytes / payload bytes` —
per engine. This lab harness measures it end to end, on real servers.

## The two numbers being compared

- **Payload bytes** — what the *application* hands over or receives:
  - TCP/UDP tests: the bytes iperf3 reports on the sending/receiving side.
  - HTTP test: the sum of request bytes + header bytes + body bytes that
    curl reports per request, summed over all requests.
- **Wire bytes** — what physically crosses the *carrier interface*:
  - Primary source: **nftables counters**, scoped to exactly the carrier
    ports of the engine under test (e.g. Matrix/tinc uses UDP+TCP port
    2097). Both directions (in/out) are counted on **both servers**.
    Scoping to ports keeps the measurement immune to SSH, panel
    heartbeats, and other background traffic on the same interface.
  - Cross-check: the `/proc/net/dev` delta of the carrier interface
    (`eth0`) over the same window. It is a superset (includes background
    traffic), so it should always be ≥ the nftables number; a large gap
    flags a noisy test window.

Both numbers are sampled as **deltas around each single test run**
(snapshot immediately before, immediately after), so overlapping traffic
cannot leak into a measurement.

## Why nftables jump chains

The harness installs one transient table `inet qlab_acct` on each server:

```
chain input  (hook input,  priority -300)
chain output (hook output, priority -300)
chain c_<engine>_<proto>_<port>_in   { counter return }
chain c_<engine>_<proto>_<port>_out  { counter return }
```

and jumps from `input`/`output` into those counter chains for each carrier
port the engine's adapter declares. The table is deleted after the run —
it adds no filtering behavior, only counting.

## Workloads

Each is run in **both directions** ("up" = Iran → Germany, "down" =
Germany → Iran; the iperf3 client always runs on the Iran server, `-R`
flips direction), and **repeated 3 times**:

| workload | what it does | what it stresses |
|---|---|---|
| `tcp_bulk` | iperf3 TCP, 10 s, 1 stream | streaming throughput, MSS-sized packets |
| `udp_s64` / `udp_s512` / `udp_s1200` / `udp_s1400` | iperf3 UDP, 10 s, fixed datagram size, rate = 70 % of the measured TCP throughput of that direction | per-packet tunnel overhead at small packet sizes (VoIP/game/QUIC-like traffic) |
| `http_small` | 200 sequential HTTP GETs of an 8 KiB object, each on a **fresh TCP connection** | many small connections: per-connection handshake, header, and framing overhead (web-browsing shape) |

The UDP rate is capped at 70 % of the measured TCP throughput so UDP loss
reflects the tunnel + path, not self-inflicted saturation. The rate is
derived per engine and per direction from an uncounted TCP probe.

## Per-test record

For every run: payload bytes, wire bytes (nft, per host per port-chain),
`/proc/net/dev` deltas, iperf3 throughput, TCP retransmits or UDP loss %,
CPU busy % of each host (from `/proc/stat` deltas), and per-process CPU
seconds for the engine process (e.g. `tincd`) and iperf3.

## Ratio definition

```
overhead_ratio = wire_bytes / payload_bytes
```

A ratio of 1.0 would mean the tunnel adds nothing. The `none` engine
adapter measures the **baseline**: the same workloads straight over the
public Internet (no tunnel), counting only the iperf3/HTTP ports — that
captures raw IP+TCP/UDP header overhead. A tunnel engine's *added*
overhead is roughly `ratio(engine) − ratio(none)` for the same workload,
though for UDP/HTTP the tunnel can also change packet-size distributions,
so the raw per-engine numbers are the primary output.

## What the numbers are for

Per the architecture brief, the panel stores a per-engine overhead ratio
and suggests `coefficient = datacenter price ratio × measured overhead`.
This harness produces those ratios on the real test path, in both
directions, per workload class — the exact shape of data the panel's
overhead accounting needs (agents should later report the same two
counters per tunnel in their heartbeat).

## Engine adapters

`scripts/bench/engines/<name>.sh` declares: the destination IP the client
connects to, the iperf/HTTP server bind address and port, the carrier
interface, the carrier port list to count, and the process names whose
CPU to sample. Adding an engine = adding one adapter file; the driver,
sampler, and reports are engine-agnostic (see `ENGINE-GUIDE.md` in
00-ADMIN for the product-side engine interface).

## Known measurement caveats (documented honestly)

1. The server-side sampling window is slightly wider than the client's
   (the one-off iperf3 server waits for the client), so the germany-side
   ratio can include a few seconds of idle keepalive traffic. The
   client-side (iran) ratio is the tight one; both are reported.
2. iperf3's UDP mode adds a small per-datagram header of its own; it is
   identical across engines and baseline, so comparisons stay fair, and
   absolute payload numbers carry that tiny constant.
3. The Iran↔Germany public path is congested at Iranian evening hours
   (~0.5 Mbit/s with visible loss on 2026-11-04). Ratios remain valid at
   any throughput, but throughput and loss numbers are
   time-of-day-dependent and must be read as "Iranian evening" numbers.
4. HTTP payload includes HTTP protocol headers — intentional: they are
   part of the application's real traffic shape.
5. TCP payload = bytes the sender wrote to the socket; retransmitted
   segments count once (iperf3 counts writes), while wire bytes count
   what actually flew — so on lossy paths the wire/payload ratio grows
   beyond pure header overhead. That effect is real cost and therefore
   part of the answer, not a bug.
