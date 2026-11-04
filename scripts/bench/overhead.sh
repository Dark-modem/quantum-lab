#!/usr/bin/env bash
# overhead.sh — traffic-overhead measurement harness (the Phase-1C key deliverable).
#
# For each tunnel engine that has an adapter in bench/engines/, run iperf3
# payload workloads (TCP bulk, UDP at several packet sizes, HTTP-like many
# small connections) in BOTH directions, and compare application payload bytes
# against carrier-interface wire bytes (nftables counters; /proc/net/dev is
# sampled too) on both ends. Repeats every measurement 3 times and reports
# mean +- stddev. An engine named "none" measures the no-tunnel baseline.
#
# Usage: overhead.sh [engine-name...]        (default: every adapter present)
# Results: results/overhead-<date>.json + results/overhead-<date>.md
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BENCH_DIR/../lib.sh"

ENGINES=("$@")
if [ ${#ENGINES[@]} -eq 0 ] || [ -z "${ENGINES[0]}" ]; then
  ENGINES=()
  for f in "$BENCH_DIR"/engines/*.sh; do ENGINES+=("$(basename "$f" .sh)"); done
fi

UDP_SIZES="64 512 1200 1400"
UDP_RATE_FALLBACK_BPS=20000000
HTTP_NREQ=200
ROWS_FILE="$QLAB_OUT/overhead-rows.$$"
touch "$ROWS_FILE"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

push_helpers() {
  ssh_push "$QL_IRAN_HOST" "$BENCH_DIR/qlab-sampler.sh" "/tmp/qlab-sampler.sh"
  ssh_push "$QL_GERMANY_HOST" "$BENCH_DIR/qlab-sampler.sh" "/tmp/qlab-sampler.sh"
  ssh_push "$QL_GERMANY_HOST" "$BENCH_DIR/qlab-httpd.py" "/tmp/qlab-httpd.py"
}

source_adapter() {
  local f="$BENCH_DIR/engines/$1.sh"
  [ -f "$f" ] || fail "no adapter for engine '$1' (expected $f)"
  # shellcheck disable=SC1090
  . "$f"
}

# nft chain naming: c_<engine>_<proto>_<port>_in|_out ; one table for all engines.
nft_setup_all() {
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    log "[$h] installing nft accounting table inet qlab_acct"
    ssh_run "$h" 'nft delete table inet qlab_acct 2>/dev/null; true' >/dev/null
    ssh_run "$h" 'nft add table inet qlab_acct
nft add chain inet qlab_acct input "{ type filter hook input priority -300; }"
nft add chain inet qlab_acct output "{ type filter hook output priority -300; }"' >/dev/null
    for eng in "${ENGINES[@]}"; do
      source_adapter "$eng"
      local proto port dir
      while read -r proto port; do
        [ -z "$proto" ] && continue
        for dir in in out; do
          ssh_run "$h" "nft add chain inet qlab_acct c_${eng}_${proto}_${port}_${dir}; nft add rule inet qlab_acct c_${eng}_${proto}_${port}_${dir} counter return" >/dev/null
        done
        ssh_run "$h" "nft add rule inet qlab_acct input $proto dport $port jump c_${eng}_${proto}_${port}_in; nft add rule inet qlab_acct output $proto sport $port jump c_${eng}_${proto}_${port}_out" >/dev/null
      done < <(engine_carrier_rules)
    done
  done
}

nft_teardown_all() {
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    ssh_run "$h" 'nft delete table inet qlab_acct 2>/dev/null; true' >/dev/null
  done
}

carrier_chains_for() { # <engine> -> "c_eng_proto_port_in c_..._out ..." space separated
  source_adapter "$1"
  local proto port
  while read -r proto port; do
    [ -z "$proto" ] && continue
    printf 'c_%s_%s_%s_in c_%s_%s_%s_out ' "$1" "$proto" "$port" "$1" "$proto" "$port"
  done < <(engine_carrier_rules)
}

# sample_remote <alias> <engine> -> snapshot text
sample_remote() {
  local h="$1" eng="$2"
  local iface procs chains
  iface="$(source_adapter "$eng"; engine_carrier_iface)"
  procs="$(source_adapter "$eng"; engine_processes)"
  chains="$(carrier_chains_for "$eng")"
  ssh_run "$h" "bash /tmp/qlab-sampler.sh '$iface' $chains -- $procs"
}

# germany_iperf_start <bind-ip> <port> — kill leftovers, start a one-off
# iperf3 server detached (150 s window), then VERIFY it is listening.
# Synchronous; returns LISTENING or NOT-LISTENING.
germany_iperf_start() {
  local bind="$1" port="$2"
  ssh_run "$QL_GERMANY_HOST" "pkill -x iperf3 2>/dev/null; sleep 1
pgrep -x iperf3 >/dev/null && { pkill -9 -x iperf3; sleep 0.5; }
nohup timeout 150 iperf3 -s -B $bind -p $port >/dev/null 2>&1 &
sleep 1
if ss -tln | grep -q ':$port ' && [ \$(pgrep -c -x iperf3 2>/dev/null || echo 0) -eq 1 ]; then
  echo LISTENING
else
  echo NOT-LISTENING
fi" | tail -1
}

# germany_sample_pre/post <engine> <tag> — synchronous sampling around a
# blocking client run.
germany_sample_pre()  { sample_remote "$QL_GERMANY_HOST" "$1" >"$QLAB_OUT/ger-$2.txt" 2>/dev/null; }
germany_sample_post() { sample_remote "$QL_GERMANY_HOST" "$1" >>"$QLAB_OUT/ger-$2.txt" 2>/dev/null; }

# iran_iperf_client <engine> <dst> <port> <tag> <iperf-args...>
iran_iperf_client() {
  local eng="$1" dst="$2" port="$3" tag="$4"; shift 4
  local args="$*"
  local iface procs chains
  iface="$(source_adapter "$eng"; engine_carrier_iface)"
  procs="$(source_adapter "$eng"; engine_processes)"
  chains="$(carrier_chains_for "$eng")"
  ssh_run "$QL_IRAN_HOST" "bash /tmp/qlab-sampler.sh '$iface' $chains -- $procs
timeout 45 iperf3 -c $dst -p $port $args -J >/tmp/qlab-iperf-$tag.json 2>/dev/null
rc=\$?
if ! grep -q '\"end\"' /tmp/qlab-iperf-$tag.json 2>/dev/null; then
  sleep 3
  timeout 45 iperf3 -c $dst -p $port $args -J >/tmp/qlab-iperf-$tag.json 2>/dev/null
  rc=\$?
fi
echo IPERF_RC \$rc
bash /tmp/qlab-sampler.sh '$iface' $chains -- $procs
echo ===JSON===
cat /tmp/qlab-iperf-$tag.json 2>/dev/null
rm -f /tmp/qlab-iperf-$tag.json"
}

# iran_http_client <engine> <dst> <port> <tag> — 200 sequential 8KB fetches,
# each on a fresh TCP connection; sums app-layer bytes; prints snapshot lines.
iran_http_client() {
  local eng="$1" dst="$2" port="$3" tag="$4"
  local iface procs chains
  iface="$(source_adapter "$eng"; engine_carrier_iface)"
  procs="$(source_adapter "$eng"; engine_processes)"
  chains="$(carrier_chains_for "$eng")"
  ssh_run "$QL_IRAN_HOST" "bash /tmp/qlab-sampler.sh '$iface' $chains -- $procs
i=1; req=0; hdr=0; dl=0; errs=0
while [ \$i -le $HTTP_NREQ ]; do
  out=\$(curl -s -o /dev/null -w '%{size_request} %{size_header} %{size_download} %{http_code}' --connect-timeout 5 --max-time 15 http://$dst:$port/obj 2>/dev/null)
  rc=\$?
  code=\$(printf '%s' \$out | awk '{print \$4}')
  if [ \$rc -ne 0 ] || [ \"\$code\" != 200 ]; then errs=\$((errs+1));
  else req=\$((req+\$(printf '%s' \$out|awk '{print \$1}'))); hdr=\$((hdr+\$(printf '%s' \$out|awk '{print \$2}'))); dl=\$((dl+\$(printf '%s' \$out|awk '{print \$3}'))); fi
  i=\$((i+1))
done
echo HTTP_SUM \$req \$hdr \$dl \$errs
bash /tmp/qlab-sampler.sh '$iface' $chains -- $procs"
}

start_http_server() {
  local eng="$1"
  source_adapter "$eng"
  local bind port
  bind="$(engine_http_bind)"
  port="$(engine_http_port)"
  ssh_run "$QL_GERMANY_HOST" "pkill -f "[q]lab-httpd" 2>/dev/null; sleep 0.3; nohup python3 /tmp/qlab-httpd.py $bind $port 8192 >/dev/null 2>&1 & echo started" >/dev/null
  sleep 1
}

stop_http_server() {
  ssh_run "$QL_GERMANY_HOST" "pkill -f "[q]lab-httpd" 2>/dev/null; echo stopped" >/dev/null
}

# ---------------------------------------------------------------------------
# parsing one run into a JSON row (python heredoc)
# ---------------------------------------------------------------------------

parse_run() { # parse_run <tag> <engine> <direction> <workload> <rep> <client-file> <ger-file>
  local tag="$1" eng="$2" dir="$3" wl="$4" rep="$5" cf="$6" gf="$7"
  python - "$tag" "$eng" "$dir" "$wl" "$rep" "$cf" "$gf" "$ROWS_FILE" <<'PYEOF'
import json, os, sys

tag, eng, direction, workload, rep, cf, gf, rows = sys.argv[1:9]

def parse_snapshot(text, start_marker=None):
    out = {"TS": None, "NF": {}, "DEV": {}, "STAT": None, "PROC": {}, "LOAD": None}
    started = start_marker is None
    for line in text.splitlines():
        if start_marker and line.startswith(start_marker):
            started = True
        if not started or not line.startswith(("TS ", "NF ", "DEV ", "STAT ", "PROC ", "LOAD ")):
            continue
        f = line.split()
        if f[0] == "TS":
            if out["TS"] is None:
                out["TS"] = int(f[1])
        elif f[0] == "NF":
            out["NF"][f[1]] = (int(f[2]), int(f[3]))
        elif f[0] == "DEV":
            out["DEV"][f[1]] = tuple(int(x) for x in f[2:6])
        elif f[0] == "STAT":
            out["STAT"] = [int(x) for x in f[1:8]]
        elif f[0] == "PROC":
            key = out["PROC"].setdefault(f[1], [0, 0])
            key[0] += int(f[2]); key[1] += int(f[3])
        elif f[0] == "LOAD":
            if out["LOAD"] is None:
                out["LOAD"] = float(f[1])
    return out

ctext = open(cf).read()
gtext = open(gf).read() if (gf and os.path.exists(gf)) else ""

iperf_rc = 1
json_text = ""
marker = None
if "IPERF_RC" in ctext:
    pre_text, rest = ctext.split("IPERF_RC", 1)
    rc_line, rest2 = rest.split("\n", 1)
    iperf_rc = int(rc_line.strip())
    post_text = rest2.split("===JSON===")[0]
    json_text = ctext.split("===JSON===")[1] if "===JSON===" in ctext else ""
elif "HTTP_SUM" in ctext:
    pre_text, rest = ctext.split("HTTP_SUM", 1)
    post_text = rest
    marker = "TS"
else:
    pre_text, post_text = ctext, ""

iran_pre = parse_snapshot(pre_text, None)
iran_post = parse_snapshot(post_text, marker)

def empty_snap():
    return {"TS": None, "NF": {}, "DEV": {}, "STAT": None, "PROC": {}, "LOAD": None}

ger_pre = empty_snap()
ger_post = empty_snap()
if gtext.count("TS ") >= 2:
    second_ts = gtext.find("TS ", gtext.find("TS ") + 3)
    ger_pre = parse_snapshot(gtext[:second_ts], None)
    ger_post = parse_snapshot(gtext[second_ts:], None)

def nf_delta(pre, post):
    out = {}
    for k, (p, b) in post["NF"].items():
        pp, pb = pre["NF"].get(k, (0, 0))
        out[k] = (p - pp, b - pb)
    return out

def dev_delta(pre, post):
    out = {}
    for k, v in post["DEV"].items():
        p = pre["DEV"].get(k, (0, 0, 0, 0))
        out[k] = tuple(v[i] - p[i] for i in range(4))
    return out

def cpu_busy_pct(pre, post):
    if not pre["STAT"] or not post["STAT"]:
        return None
    a, b = pre["STAT"], post["STAT"]
    d = [max(0, b[i] - a[i]) for i in range(7)]
    tot = sum(d)
    if tot == 0:
        return None
    idle = d[3] + d[4]
    return round(100.0 * (tot - idle) / tot, 2)

def proc_seconds(pre, post):
    out = {}
    for k, (u, s) in post["PROC"].items():
        pu, ps = pre["PROC"].get(k, (0, 0))
        out[k] = round(((u - pu) + (s - ps)) / 100.0, 3)
    return out

payload = throughput = retransmits = udp_loss = duration = None
http_errors = None

if "IPERF_RC" in ctext and json_text.strip():
    try:
        j = json.loads(json_text)
        end = j.get("end", {})
        sending = end.get("sum_sent", {}) or {}
        receiving = end.get("sum_received", {}) or {}
        if direction == "up":
            payload = (sending.get("bytes") or receiving.get("bytes"))
        else:
            payload = (receiving.get("bytes") or sending.get("bytes"))
        throughput = (receiving.get("bits_per_second") or sending.get("bits_per_second"))
        retransmits = sending.get("retransmits")
        udp_loss = receiving.get("lost_percent", sending.get("lost_percent"))
        duration = receiving.get("seconds") or sending.get("seconds")
    except Exception:
        iperf_rc = 2
elif "HTTP_SUM" in ctext:
    parts = ctext.split("HTTP_SUM", 1)[1].splitlines()[0].split()
    req, hdr, dl = int(parts[0]), int(parts[1]), int(parts[2])
    http_errors = int(parts[3])
    payload = req + hdr + dl
    duration = ((iran_post["TS"] or 0) - (iran_pre["TS"] or 0)) / 1000.0
    throughput = payload * 8 / duration if duration and duration > 0 else None

row = {
    "tag": tag, "engine": eng, "direction": direction, "workload": workload, "rep": int(rep),
    "iperf_rc": iperf_rc,
    "payload_bytes": payload,
    "throughput_bps": throughput,
    "duration_s": duration,
    "retransmits": retransmits,
    "udp_loss_percent": udp_loss,
    "http_errors": http_errors,
    "wire_bytes": {"iran": nf_delta(iran_pre, iran_post), "germany": nf_delta(ger_pre, ger_post)},
    "dev_delta": {"iran": {k: list(v) for k, v in dev_delta(iran_pre, iran_post).items()},
                  "germany": {k: list(v) for k, v in dev_delta(ger_pre, ger_post).items()}},
    "cpu_busy_percent": {"iran": cpu_busy_pct(iran_pre, iran_post),
                          "germany": cpu_busy_pct(ger_pre, ger_post)},
    "proc_cpu_seconds": {"iran": proc_seconds(iran_pre, iran_post),
                          "germany": proc_seconds(ger_pre, ger_post)},
    "window_ms": {"iran": (iran_post["TS"] or 0) - (iran_pre["TS"] or 0),
                   "germany": (ger_post["TS"] or 0) - (ger_pre["TS"] or 0)},
    "load": {"iran": iran_post["LOAD"], "germany": ger_post["LOAD"]},
}
with open(rows, "a") as fh:
    fh.write(json.dumps(row) + "\n")
iw = sum(b for _p, b in row["wire_bytes"]["iran"].values())
gw = sum(b for _p, b in row["wire_bytes"]["germany"].values())
ratio_iran = (iw / payload) if payload else None
print(f"ROW {tag} rc={iperf_rc} payload={payload} wire_iran={iw} wire_ger={gw} "
      f"ratio_iran={ratio_iran and round(ratio_iran, 4)} thr={throughput and int(throughput)}")
PYEOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  log "engines to measure: ${ENGINES[*]}"
  push_helpers
  nft_setup_all

  log "checking engine readiness"
  declare -A READY
  for eng in "${ENGINES[@]}"; do
    source_adapter "$eng"
    if engine_ready; then READY[$eng]=1; log "[$eng] ready"; else READY[$eng]=0; log "[$eng] NOT ready — marked unavailable"; fi
  done

  log "TCP probe per engine+direction (sets the UDP test rate)"
  declare -A UDP_RATE_BPS
  for eng in "${ENGINES[@]}"; do
    [ "${READY[$eng]}" = 1 ] || continue
    source_adapter "$eng"
    local dst bind; dst="$(engine_dest_ip)"; bind="$(engine_server_bind)"
    for dir in up down; do
      local flip=""; [ "$dir" = down ] && flip="-R"
      local listen; listen="$(germany_iperf_start "$bind" "$IPERF_PORT")"
      [ "$listen" = LISTENING ] || log "WARN: iperf server not listening for probe-$eng-$dir"
      germany_sample_pre "$eng" "probe-$eng-$dir"
      local out
      out="$(iran_iperf_client "$eng" "$dst" "$IPERF_PORT" "probe-$eng-$dir" "-t 8 $flip")"
      germany_sample_post "$eng" "probe-$eng-$dir"
      local bps
      bps="$(printf '%s\n' "$out" | python -c '
import json,sys
try:
    t=sys.stdin.read(); j=json.loads(t.split("===JSON===")[1])
    print(int(j.get("end",{}).get("sum_received",{}).get("bits_per_second") or 0))
except Exception: print(0)')"
      UDP_RATE_BPS["${eng}_${dir}"]="$bps"
      log "[$eng] $dir TCP probe: $bps bps"
    done
  done

  log "measurement matrix: 3 reps x workloads x directions per engine"
  for eng in "${ENGINES[@]}"; do
    if [ "${READY[$eng]}" != 1 ]; then
      printf '%s\n' "{\"engine\":\"$eng\",\"unavailable\":true}" >>"$ROWS_FILE"
      continue
    fi
    source_adapter "$eng"
    local dst bind; dst="$(engine_dest_ip)"; bind="$(engine_server_bind)"

    start_http_server "$eng"
    local http_port; http_port="$(source_adapter "$eng"; engine_http_port)"

    for dir in up down; do
      local flip=""; [ "$dir" = down ] && flip="-R"
      local rate="${UDP_RATE_BPS[${eng}_${dir}]:-0}"
      [ "${rate:-0}" -lt 1000000 ] 2>/dev/null && rate="$UDP_RATE_FALLBACK_BPS"
      local udpargs="-u -b $rate"

      for rep in 1 2 3; do
        local tag="${eng}_${dir}_tcp_bulk_r$rep"
        local listen; listen="$(germany_iperf_start "$bind" "$IPERF_PORT")"
        [ "$listen" = LISTENING ] || log "WARN: iperf server not listening for $tag"
        germany_sample_pre "$eng" "$tag"
        iran_iperf_client "$eng" "$dst" "$IPERF_PORT" "$tag" "-t 10 $flip" >"$QLAB_OUT/cli-$tag.txt" 2>/dev/null
        germany_sample_post "$eng" "$tag"
        parse_run "$tag" "$eng" "$dir" "tcp_bulk" "$rep" "$QLAB_OUT/cli-$tag.txt" "$QLAB_OUT/ger-$tag.txt" || true
        sleep 1
      done

      for s in $UDP_SIZES; do
        for rep in 1 2 3; do
          local tag="${eng}_${dir}_udp_s${s}_r$rep"
          local listen; listen="$(germany_iperf_start "$bind" "$IPERF_PORT")"
          [ "$listen" = LISTENING ] || log "WARN: iperf server not listening for $tag"
          germany_sample_pre "$eng" "$tag"
          iran_iperf_client "$eng" "$dst" "$IPERF_PORT" "$tag" "-t 10 $flip $udpargs -l $s" >"$QLAB_OUT/cli-$tag.txt" 2>/dev/null
          germany_sample_post "$eng" "$tag"
          parse_run "$tag" "$eng" "$dir" "udp_s$s" "$rep" "$QLAB_OUT/cli-$tag.txt" "$QLAB_OUT/ger-$tag.txt" || true
          sleep 1
        done
      done

      for rep in 1 2 3; do
        local tag="${eng}_${dir}_http_r$rep"
        germany_sample_pre "$eng" "$tag"
        iran_http_client "$eng" "$dst" "$http_port" "$tag" >"$QLAB_OUT/cli-$tag.txt" 2>/dev/null
        germany_sample_post "$eng" "$tag"
        parse_run "$tag" "$eng" "$dir" "http_small" "$rep" "$QLAB_OUT/cli-$tag.txt" "$QLAB_OUT/ger-$tag.txt" || true
        sleep 1
      done
    done
    stop_http_server
    log "[$eng] done"
  done

  nft_teardown_all
  local rjson="$QLAB_RESULTS/overhead-$QLAB_TS.json"
  local rmd="$QLAB_RESULTS/overhead-$QLAB_TS.md"
  python "$BENCH_DIR/report.py" "$ROWS_FILE" "$rjson" "$rmd" "$QLAB_TS" && log "report: $rmd"
  mkdir -p "$QLAB_RESULTS/raw" && cp "$ROWS_FILE" "$QLAB_RESULTS/raw/overhead-rows-$QLAB_TS.jsonl"
  rm -f "$ROWS_FILE"
  log "bench complete"
}

main "$@"
