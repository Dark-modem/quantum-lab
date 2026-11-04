#!/usr/bin/env python3
# report.py — aggregate overhead bench rows into the JSON + markdown deliverable.
# Usage: report.py <rows.jsonl> <out.json> <out.md> <date>
import json
import statistics
import sys
from collections import defaultdict

rows_file, out_json, out_md, ts = sys.argv[1:5]

rows = []
for line in open(rows_file):
    line = line.strip()
    if not line:
        continue
    rows.append(json.loads(line))

def wire_total(row, host):
    wb = row.get("wire_bytes", {}).get(host, {})
    return sum(b for _p, b in wb.values())

def dev_total(row, host):
    dd = row.get("dev_delta", {}).get(host, {})
    return sum(v[0] + v[2] for v in dd.values())  # rxb + txb

# ---- aggregate: (engine, direction, workload) -> stats ----
groups = defaultdict(list)
unavailable = set()
for r in rows:
    if r.get("unavailable"):
        unavailable.add(r["engine"])
        continue
    groups[(r["engine"], r["direction"], r["workload"])].append(r)

def summarize(rows_):
    """rows_ = successful reps of one (engine, direction, workload)."""
    ratios_iran = []
    ratios_ger = []
    ratios_dev = []
    thr = []
    losses = []
    retx = []
    cpu_iran = []
    cpu_ger = []
    eng_cpu = defaultdict(list)
    for r in rows_:
        p = r.get("payload_bytes")
        if p:
            ratios_iran.append(wire_total(r, "iran") / p)
            ratios_ger.append(wire_total(r, "germany") / p)
            ratios_dev.append(dev_total(r, "iran") / p)
        if r.get("throughput_bps"):
            thr.append(r["throughput_bps"])
        if r.get("udp_loss_percent") is not None:
            losses.append(r["udp_loss_percent"])
        if r.get("retransmits") is not None:
            retx.append(r["retransmits"])
        if r.get("cpu_busy_percent", {}).get("iran") is not None:
            cpu_iran.append(r["cpu_busy_percent"]["iran"])
        if r.get("cpu_busy_percent", {}).get("germany") is not None:
            cpu_ger.append(r["cpu_busy_percent"]["germany"])
        for host in ("iran", "germany"):
            for pname, secs in (r.get("proc_cpu_seconds", {}).get(host) or {}).items():
                eng_cpu[f"{host}:{pname}"].append(secs)

    def ms(vals):
        if not vals:
            return None
        return {
            "mean": round(statistics.mean(vals), 4),
            "stdev": round(statistics.stdev(vals), 4) if len(vals) > 1 else 0.0,
            "n": len(vals),
        }

    return {
        "n_successful": len(rows_),
        "n_total": sum(1 for _ in rows_),
        "ratio_wire_payload_iran": ms(ratios_iran),
        "ratio_wire_payload_germany": ms(ratios_ger),
        "ratio_dev_bytes_payload": ms(ratios_dev),
        "throughput_bps": ms(thr),
        "udp_loss_percent": ms(losses),
        "tcp_retransmits": ms(retx),
        "cpu_busy_percent": {"iran": ms(cpu_iran), "germany": ms(cpu_ger)},
        "proc_cpu_seconds_per_run": {k: ms(v) for k, v in eng_cpu.items()},
    }

summary = {}
for (eng, direction, workload), rs in sorted(groups.items()):
    ok = [r for r in rs if r.get("payload_bytes") and r.get("counters_valid", True)]
    summary[f"{eng}|{direction}|{workload}"] = summarize(ok)

# keep per-rep raw rows in the JSON for reproducibility
out = {
    "date": ts,
    "unavailable_engines": sorted(unavailable),
    "summary": summary,
    "raw_rows": rows,
}
json.dump(out, open(out_json, "w"), indent=1)

# ---- markdown ----
WLS = ["tcp_bulk", "udp_s64", "udp_s512", "udp_s1200", "udp_s1400", "http_small"]
engines = sorted({r["engine"] for r in rows if not r.get("unavailable")})

def fmt(x, pct=False, bps=False):
    if x is None:
        return "—"
    if bps:
        return f"{x/1e6:.2f} Mb/s" if x >= 1e6 else f"{x/1e3:.0f} kb/s"
    if pct:
        return f"{x:.1f}%"
    return f"{x:.3f}"

lines = []
lines.append(f"# Traffic overhead results — {ts}")
lines.append("")
lines.append("Wire bytes = nftables counters on the carrier interface (mesh/test ports), "
             "payload bytes = application-level bytes (iperf3 sent/received, HTTP sum). "
             "Ratios are wire/payload; `iran` is the client-side view, `germany` the server-side view. "
             "Each cell is mean ± stdev over 3 reps.")
lines.append("")

for eng in engines:
    lines.append(f"## Engine: {eng}")
    lines.append("")
    lines.append("| direction | workload | ratio (iran) | ratio (germany) | throughput | loss/retrans | CPU% iran | CPU% germany | n |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for direction in ("up", "down"):
        for wl in WLS:
            key = f"{eng}|{direction}|{wl}"
            if key not in summary:
                continue
            s = summary[key]
            r_i = s["ratio_wire_payload_iran"]
            r_g = s["ratio_wire_payload_germany"]
            thr = s["throughput_bps"]["mean"] if s["throughput_bps"] else None
            if wl.startswith("udp"):
                loss = s["udp_loss_percent"]
                loss_txt = f"{loss['mean']:.1f}% ±{loss['stdev']:.1f}" if loss else "—"
            elif wl == "tcp_bulk":
                rt = s["tcp_retransmits"]
                loss_txt = f"{rt['mean']:.0f} retx" if rt else "—"
            else:
                loss_txt = "—"
            cpu_i = s["cpu_busy_percent"]["iran"]
            cpu_g = s["cpu_busy_percent"]["germany"]
            lines.append(
                f"| {direction} | {wl} | {fmt(r_i['mean'] if r_i else None)} ±{fmt(r_i['stdev'] if r_i else None)} "
                f"| {fmt(r_g['mean'] if r_g else None)} ±{fmt(r_g['stdev'] if r_g else None)} "
                f"| {fmt(thr, bps=True)} | {loss_txt} "
                f"| {fmt(cpu_i['mean'] if cpu_i else None, pct=True)} | {fmt(cpu_g['mean'] if cpu_g else None, pct=True)} "
                f"| {s['n_successful']}/3 |")
    lines.append("")

if unavailable:
    lines.append(f"**Engines unavailable (marked UNVERIFIED): {', '.join(sorted(unavailable))}**")
    lines.append("")

lines.append("_Overhead note: `none` is the no-tunnel baseline (raw IP/TCP/UDP protocol overhead on the "
             "public path). A tunnel engine's true overhead ≈ its ratio minus the baseline ratio._")
lines.append("")

open(out_md, "w").write("\n".join(lines))
print(f"wrote {out_json} and {out_md} ({len(rows)} rows, {len(summary)} groups)")
