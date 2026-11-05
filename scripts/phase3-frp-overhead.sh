#!/usr/bin/env bash
# phase3-frp-overhead.sh — overhead measurement for the FRP engine using the
# same method as bench/overhead.sh (pre/post counter deltas around each run,
# 3 reps). FRP-specific plumbing:
#   - data path: germany(iperf3 client -> 127.0.0.1:34001) -> frps -> frpc(iran)
#     -> iran(iperf3 server on 127.0.0.1:5201). The tunnel leg carries ALL
#     bytes on TCP port 7000 (frp control+data multiplexed) — that port is
#     the wire view on BOTH hosts (nft counters, in+out).
#   - "down" = germany -> iran (default iperf3), "up" = -R. Labels follow the
#     Iran-centric convention of the matrix results.
#   - payload = iperf3 client bytes (germany side).
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BENCH_DIR/lib.sh"

UDP_SIZES="64 512 1200 1400"
ROWS_FILE="$QLAB_OUT/frp-overhead-rows.$$"
touch "$ROWS_FILE"

push_helpers() {
  ssh_push "$QL_IRAN_HOST" "$BENCH_DIR/qlab-sampler.sh" "/tmp/qlab-sampler.sh"
  ssh_push "$QL_GERMANY_HOST" "$BENCH_DIR/qlab-sampler.sh" "/tmp/qlab-sampler.sh"
}

# nft accounting: tcp 7000 both directions on both hosts.
nft_setup() {
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    log "[$h] nft accounting for frp (tcp 7000 in/out)"
    ssh_run "$h" 'nft delete table inet qlab_frp 2>/dev/null; nft add table inet qlab_frp
nft add chain inet qlab_frp input "{ type filter hook input priority -300; }"
nft add chain inet qlab_frp output "{ type filter hook output priority -300; }"
nft add chain inet qlab_frp c_tcp_7000_in; nft add rule inet qlab_frp c_tcp_7000_in counter return
nft add chain inet qlab_frp c_tcp_7000_out; nft add rule inet qlab_frp c_tcp_7000_out counter return
nft add rule inet qlab_frp input tcp dport 7000 jump c_tcp_7000_in
nft add rule inet qlab_frp output tcp sport 7000 jump c_tcp_7000_out' >/dev/null
    local got
    got="$(ssh_run "$h" "nft list table inet qlab_frp 2>/dev/null | grep -c 'chain c_'")"
    [ "$got" = 2 ] || fail "[$h] frp accounting incomplete ($got/2 chains)"
  done
}

nft_teardown() {
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    ssh_run "$h" 'nft delete table inet qlab_frp 2>/dev/null; true' >/dev/null
  done
}

# sampler with the frp chain set (qlab_frp table — sampler reads qlab_acct,
# so a tiny inline variant reads the right table)
frp_sample() { # frp_sample <alias>
  ssh_run "$1" 'T=$(date +%s%3N); echo "TS $T"
for c in c_tcp_7000_in c_tcp_7000_out; do
  line=$(nft list chain inet qlab_frp "$c" 2>/dev/null | grep -oE "counter packets [0-9]+ bytes [0-9]+" | head -1)
  p=$(printf "%s" "$line" | awk "{print \$3}"); b=$(printf "%s" "$line" | awk "{print \$5}")
  echo "NF $c ${p:-0} ${b:-0}"
done
head -1 /proc/stat | awk "{print \"STAT\", \$2, \$3, \$4, \$5, \$6, \$7, \$8}"
echo "LOAD $(awk "{print \$1}" /proc/loadavg)"'
}

iperf_server_start() { # on iran, loopback bind
  ssh_run "$QL_IRAN_HOST" "pkill -x iperf3 2>/dev/null; sleep 0.5
nohup timeout 90 iperf3 -s -1 -B 127.0.0.1 -p 5201 >/dev/null 2>&1 &
sleep 1" >/dev/null
}

sample_pair() { # sample_pair <tag>
  frp_sample "$QL_GERMANY_HOST" >"$QLAB_OUT/fger-$tag.txt" 2>/dev/null
  frp_sample "$QL_IRAN_HOST" >"$QLAB_OUT/firan-$tag.txt" 2>/dev/null
}

run_iperf() { # run_iperf <tag> <args...>
  local tag="$1"; shift
  ssh_run "$QL_GERMANY_HOST" "timeout 45 iperf3 -c 127.0.0.1 -p 34001 $* -J >/tmp/qlab-frp-$tag.json 2>/dev/null
echo ===JSON===
cat /tmp/qlab-frp-$tag.json 2>/dev/null
rm -f /tmp/qlab-frp-$tag.json"
}

parse_row() { # parse_row <tag> <direction> <workload> <rep> <client-out>
  local tag="$1" dir="$2" wl="$3" rep="$4" cf="$5"
  python - "$tag" "$dir" "$wl" "$rep" "$cf" "$ROWS_FILE" "$QLAB_OUT/fger-$tag.txt" "$QLAB_OUT/firan-$tag.txt" <<'PYEOF'
import json, sys
tag, direction, workload, rep, cf, rows, gf, irf = sys.argv[1:9]

def snap(text):
    out = {"TS": None, "NF": {}, "STAT": None}
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "TS" and out["TS"] is None:
            out["TS"] = int(f[1])
        elif f[0] == "NF":
            out["NF"][f[1]] = (int(f[2]), int(f[3]))
        elif f[0] == "STAT":
            out["STAT"] = [int(x) for x in f[1:8]]
    return out

def delta(a, b):
    return {k: (b["NF"][k][0] - a["NF"].get(k, (0, 0))[0], b["NF"][k][1] - a["NF"].get(k, (0, 0))[1])
            for k in b["NF"]}

def busy(a, b):
    if not a["STAT"] or not b["STAT"]:
        return None
    d = [max(0, b["STAT"][i] - a["STAT"][i]) for i in range(7)]
    tot = sum(d)
    return round(100.0 * (tot - d[3] - d[4]) / tot, 2) if tot else None

ctext = open(cf).read()
gtext = open(gf).read()
itext = open(irf).read()

# client output: pre-iperf nothing... layout: IPERF_RC line first (no pre-snapshot on client),
# then ===JSON=== + json
iperf_rc = 1
payload = thr = None
if "===JSON===" in ctext:
    try:
        j = json.loads(ctext.split("===JSON===")[1])
        end = j.get("end", {})
        s, r = end.get("sum_sent", {}) or {}, end.get("sum_received", {}) or {}
        if direction == "down":
            payload = (s.get("bytes") or r.get("bytes"))
        else:
            payload = (r.get("bytes") or s.get("bytes"))
        thr = r.get("bits_per_second") or s.get("bits_per_second")
        iperf_rc = 0 if payload else 2
    except Exception:
        iperf_rc = 2

# germany sampled BEFORE the client ran (pre) and AFTER (post): the sample_pair
# wraps the client run; the first TS in each file is pre, second is post.
def two_snaps(text):
    parts = text.split("TS ")
    pre = snap("TS " + parts[1]) if len(parts) > 2 else None
    post = snap("TS " + parts[2]) if len(parts) > 2 else None
    return pre, post

ger_pre, ger_post = two_snaps(gtext)
iran_pre, iran_post = two_snaps(itext)
row = {
    "tag": tag, "engine": "frp", "direction": direction, "workload": workload, "rep": int(rep),
    "iperf_rc": iperf_rc, "payload_bytes": payload, "throughput_bps": thr,
    "counters_valid": bool(ger_pre and ger_post and iran_pre and iran_post),
    "wire_bytes": {"germany": delta(ger_pre, ger_post) if ger_pre else {},
                    "iran": delta(iran_pre, iran_post) if iran_pre else {}},
    "cpu_busy_percent": {"germany": busy(ger_pre, ger_post), "iran": busy(iran_pre, iran_post)},
}
with open(rows, "a") as fh:
    fh.write(json.dumps(row) + "\n")
gw = sum(b for _p, b in row["wire_bytes"]["germany"].values())
iw = sum(b for _p, b in row["wire_bytes"]["iran"].values())
ratio = (gw / payload) if payload else None
print(f"ROW {tag} rc={iperf_rc} payload={payload} wire_ger={gw} wire_iran={iw} "
      f"ratio_ger={ratio and round(ratio, 4)} thr={thr and int(thr)}")
PYEOF
}

main() {
  push_helpers
  nft_setup
  log "frp overhead: 3 reps x {tcp_bulk, udp s64/s512/s1200/s1400} x {down, up}"

  for dir in down up; do
    local flip=""; [ "$dir" = up ] && flip="-R"
    for rep in 1 2 3; do
      # TCP bulk
      local tag="frp_${dir}_tcp_bulk_r$rep"
      iperf_server_start; sleep 1
      sample_pair "$tag"
      run_iperf "$tag" "-t 10 $flip" >"$QLAB_OUT/cli-$tag.txt" 2>/dev/null
      sample_pair_append "$tag"
      parse_row "$tag" "$dir" "tcp_bulk" "$rep" "$QLAB_OUT/cli-$tag.txt" || true
      sleep 1
      # UDP sizes at a fixed 30 Mb/s (path measured ~60-110; 30 keeps loss low)
      for s in $UDP_SIZES; do
        local tag2="frp_${dir}_udp_s${s}_r$rep"
        iperf_server_start; sleep 1
        sample_pair "$tag2"
        run_iperf "$tag2" "-t 10 $flip -u -b 30000000 -l $s" >"$QLAB_OUT/cli-$tag2.txt" 2>/dev/null
        sample_pair_append "$tag2"
        parse_row "$tag2" "$dir" "udp_s$s" "$rep" "$QLAB_OUT/cli-$tag2.txt" || true
        sleep 1
      done
    done
  done

  nft_teardown
  log "raw rows: $ROWS_FILE"
}

sample_pair_append() { # post samples appended to the same files
  frp_sample "$QL_GERMANY_HOST" >>"$QLAB_OUT/fger-$1.txt" 2>/dev/null
  frp_sample "$QL_IRAN_HOST" >>"$QLAB_OUT/firan-$1.txt" 2>/dev/null
}

main "$@"
