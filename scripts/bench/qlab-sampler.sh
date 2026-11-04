#!/usr/bin/env bash
# qlab-sampler.sh — runs ON a lab server. Emits one machine-readable snapshot:
#
#   TS <unix-ms>
#   NF <chain-name> <packets> <bytes>        (one line per nft counter chain)
#   DEV <iface> <rxb> <rxp> <txb> <txp>      (from /proc/net/dev)
#   STAT <user> <nice> <sys> <idle> <iowait> <irq> <softirq>   (/proc/stat line 1)
#   PROC <comm> <utime> <stime>              (one line per process of interest)
#   LOAD <load1>
#
# Usage: qlab-sampler.sh <iface> <chain...> -- <proc-comm...>
set -u
IFACE="${1:?iface}"; shift

chains=()
process_names=()
seen_sep=0
for a in "$@"; do
  if [ "$a" = "--" ]; then seen_sep=1; continue; fi
  if [ "$seen_sep" = 1 ]; then process_names+=("$a"); else chains+=("$a"); fi
done

echo "TS $(date +%s%N | cut -c1-13)"

for c in "${chains[@]:-}"; do
  [ -z "$c" ] && continue
  line="$(nft list chain inet qlab_acct "$c" 2>/dev/null | grep -oE 'counter packets [0-9]+ bytes [0-9]+' | head -1)"
  if [ -z "$line" ]; then
    echo "NF $c MISSING"
  else
    p="$(printf '%s' "$line" | awk '{print $3}')"
    b="$(printf '%s' "$line" | awk '{print $5}')"
    echo "NF $c ${p:-0} ${b:-0}"
  fi
done

# /proc/net/dev: " iface: rxb rxp rxerr rxdrop ... txb txp ..."
line="$(grep -E "^ *$IFACE:" /proc/net/dev || true)"
if [ -n "$line" ]; then
  # unquoted expansion on purpose: split the 16 counters on IFS
  vals=(${line#*:})
  if [ "${#vals[@]}" -ge 10 ]; then
    echo "DEV $IFACE ${vals[0]} ${vals[1]} ${vals[8]} ${vals[9]}"
  else
    echo "DEV $IFACE 0 0 0 0"
  fi
else
  echo "DEV $IFACE 0 0 0 0"
fi

head -1 /proc/stat | awk '{print "STAT", $2, $3, $4, $5, $6, $7, $8}'

for pn in "${process_names[@]:-}"; do
  [ -z "$pn" ] && continue
  for pid in $(pgrep -x "$pn" 2>/dev/null); do
    stats="$(awk '{print $14, $15}' "/proc/$pid/stat" 2>/dev/null)" || continue
    [ -n "$stats" ] && echo "PROC $pn $stats"
  done
done

echo "LOAD $(awk '{print $1}' /proc/loadavg)"
