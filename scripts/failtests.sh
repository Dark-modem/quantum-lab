#!/usr/bin/env bash
# failtests.sh — failure injection + detection/recovery measurement.
#
# Tests (all scoped so SSH control access is never affected):
#   kill-hub      SIGKILL tincd on germany (hub); systemd Restart=on-failure
#                 (RestartSec=3) restarts it. Measures data-plane recovery.
#   kill-node     same on iran (node).
#   netem10       tc netem loss 10% on iran's carrier, mesh port only.
#                 Measures inner-ping loss/latency degradation + recovery.
#   blackhole     nft drop of mesh port both directions on iran (100% link cut).
#                 Measures detection time (inner ping fails) and recovery time
#                 (ping restored) after the rule is removed.
#
# For every test we also poll the panel for the agent's reported tunnel health
# to capture how quickly the PRODUCT notices (vs the raw data plane).
#
# Usage: failtests.sh [kill-hub kill-node netem10 blackhole]
# Results: results/failtests-<date>.json + .md
set -uo pipefail
. "$(dirname "$0")/lib.sh"

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ] || [ -z "${TESTS[0]}" ]; then
  TESTS=(kill-hub kill-node netem10 blackhole)
fi

RESULT_JSON="$QLAB_RESULTS/failtests-$QLAB_TS.json"
RESULT_MD="$QLAB_RESULTS/failtests-$QLAB_TS.md"
ROWS_FILE="$QLAB_OUT/failtest-rows.$$"
touch "$ROWS_FILE"

CRED_FILE="$HOME/.qlab-panel-cred"
PANEL_COOKIE_JAR_REMOTE="/tmp/qlab-cookies"
MESH_UNIT_GLOB="quantum-matrix*.service"

panel_base() { grep -m1 "Base Path:" "$CRED_FILE" | sed 's|.*Base Path: /||; s| (UNCHANGED)||; s| ||g'; }
panel_user() { grep -m1 "Username:" "$CRED_FILE" | sed 's|.*Username:  ||'; }
panel_pass() { grep -m1 "Password:" "$CRED_FILE" | sed 's|.*Password:  ||'; }

panel_login() {
  local base body
  base="$(panel_base)"
  ssh_run "$QL_GERMANY_HOST" "rm -f $PANEL_COOKIE_JAR_REMOTE" >/dev/null
  body="{\"username\":$(json_escape "$(panel_user)"),\"password\":$(json_escape "$(panel_pass)")}"
  printf '%s' "$body" | ssh_run "$QL_GERMANY_HOST" "curl -s -o /dev/null -w '%{http_code}' -X POST -b $PANEL_COOKIE_JAR_REMOTE -c $PANEL_COOKIE_JAR_REMOTE -H 'Content-Type: application/json' -d @- http://127.0.0.1:$PANEL_PORT/$base/api/login" >/dev/null
}

# agent_health_state <alias> — tunnel health as the AGENT reports it (via panel)
agent_health_state() {
  local h="$1" base csrf
  base="$(panel_base)"
  csrf="$(ssh_run "$QL_GERMANY_HOST" "grep gre_csrf $PANEL_COOKIE_JAR_REMOTE 2>/dev/null | awk '{print \$7}'")"
  local name="lab-iran"; [ "$h" = "$QL_GERMANY_HOST" ] && name="lab-germany"
  ssh_run "$QL_GERMANY_HOST" "curl -s -b $PANEL_COOKIE_JAR_REMOTE -H 'X-CSRF-Token: $csrf' http://127.0.0.1:$PANEL_PORT/$base/api/agents" | python -c '
import json,sys
try:
    d=json.load(sys.stdin)
    agents=d if isinstance(d,list) else d.get("agents",[])
    for a in agents:
        if sys.argv[1] in (a.get("name") or ""):
            st=a.get("last_state") or {}
            print(json.dumps({"health":st.get("health",[]),"matrix":st.get("matrix",[])}))
except Exception as e:
    print("{}")
' "$name" 2>/dev/null
}

mesh_unit_on() { # mesh_unit_on <alias> — actual running matrix unit name
  ssh_run "$1" "systemctl list-units --type=service --no-legend 2>/dev/null | awk '/quantum-matrix/{print \$1; exit}'"
}

# inner_ping <alias> <ip> — single ping over the mesh; prints ok/timeout
inner_ping() {
  ssh_run "$1" "ping -c 1 -W 2 $2 >/dev/null 2>&1 && echo ok || echo timeout" 2>/dev/null
}

epoch() { date +%s%3N; }

# ---------------------------------------------------------------------------
# generic outage measurement
#   measure_outage <test-name> <inject-alias> <inject-remote-cmd> <recover-alias> <recover-remote-cmd> <auto-recover:yes|no>
# ---------------------------------------------------------------------------

measure_outage() {
  local name="$1" inj_h="$2" inj_cmd="$3" rec_h="$4" rec_cmd="$5" auto="$6"
  log "[$name] injecting failure"
  panel_login

  local t0; t0="$(epoch)"
  ssh_run "$inj_h" "$inj_cmd" >/dev/null

  # poll data plane every 2s (up to 150s) from both views
  local iran_first_fail="" ger_first_fail="" iran_recover="" ger_recover=""
  local deadline=$(( $(date +%s) + 150 ))
  local i=0 health_before health_after health_flip_s=""
  health_before="$(agent_health_state "$QL_IRAN_HOST")"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    i=$((i+1))
    local pi pg
    pi="$(inner_ping "$QL_IRAN_HOST" "$MESH_HUB_IP")"
    pg="$(inner_ping "$QL_GERMANY_HOST" "$MESH_NODE_IP")"
    [ -z "$iran_first_fail" ] && [ "$pi" = timeout ] && iran_first_fail="$(epoch)"
    [ -z "$ger_first_fail" ] && [ "$pg" = timeout ] && ger_first_fail="$(epoch)"
    if [ -n "$iran_first_fail" ] && [ -z "$iran_recover" ] && [ "$pi" = ok ] && [ "$i" -gt 1 ]; then
      # require 2 consecutive successes to call it recovered
      local pi2; pi2="$(inner_ping "$QL_IRAN_HOST" "$MESH_HUB_IP")"
      [ "$pi2" = ok ] && iran_recover="$(epoch)"
    fi
    if [ -n "$iran_recover" ]; then break; fi
    if [ "$auto" = no ] && [ "$(epoch)" -ge $(( t0 + 40000 )) ]; then
      log "[$name] applying manual recovery"
      ssh_run "$rec_h" "$rec_cmd" >/dev/null
      auto=delayed
    fi
    if [ -z "$health_flip_s" ]; then
      health_after="$(agent_health_state "$QL_IRAN_HOST")"
      [ "$health_after" != "$health_before" ] && health_flip_s=$(( ( $(epoch) - t0 ) / 1000 ))
    fi
    sleep 2
  done

  local detected=$(( ${iran_first_fail:-$t0} - t0 ))
  local recovered=$(( ${iran_recover:-0} - t0 ))
  local ger_detected="null"
  [ -n "$ger_first_fail" ] && ger_detected=$(( ger_first_fail - t0 ))
  local recovered_val="null"
  [ -n "$iran_recover" ] && recovered_val="$recovered"
  local row
  row=$(printf '{"test":"%s","inject_ms":%s,"fail_detected_ms":%s,"fail_detected_germany_ms":%s,"recovered_ms":%s,"agent_health_flip_s":%s,"health_before":%s,"health_after":%s}' \
    "$name" "$t0" "$detected" \
    "$ger_detected" \
    "$recovered_val" \
    "${health_flip_s:-null}" "$(printf '%s' "$health_before" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo null)" "$(printf '%s' "$(agent_health_state "$QL_IRAN_HOST")" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo null)")
  printf '%s\n' "$row" >>"$ROWS_FILE"
  log "[$name] detected=${detected}ms recovered=${recovered:-NA}ms"
  # always clean the lab state
  ssh_run "$QL_IRAN_HOST" "tc qdisc del dev eth0 root 2>/dev/null; true" >/dev/null
  sleep 3
}

# ---------------------------------------------------------------------------
# individual tests
# ---------------------------------------------------------------------------

t_kill_hub() {
  local unit; unit="$(mesh_unit_on "$QL_GERMANY_HOST")"
  [ -n "$unit" ] || { log "no matrix unit on germany; skip kill-hub"; return; }
  measure_outage "kill-hub" "$QL_GERMANY_HOST" "pid=\$(systemctl show -p MainPID --value $unit); kill -9 \$pid; echo killed \$pid" \
                 "$QL_GERMANY_HOST" "true" yes
}

t_kill_node() {
  local unit; unit="$(mesh_unit_on "$QL_IRAN_HOST")"
  [ -n "$unit" ] || { log "no matrix unit on iran; skip kill-node"; return; }
  measure_outage "kill-node" "$QL_IRAN_HOST" "pid=\$(systemctl show -p MainPID --value $unit); kill -9 \$pid; echo killed \$pid" \
                 "$QL_IRAN_HOST" "true" yes
}

t_netem10() {
  log "[netem10] adding scoped netem (10% loss, mesh port only) on iran"
  panel_login
  ssh_run "$QL_IRAN_HOST" "tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root handle 1: prio bands 3; tc qdisc add dev eth0 parent 1:3 handle 30: netem loss 10% limit 200; tc filter add dev eth0 parent 1: protocol ip u32 match ip sport $MESH_PORT 0xffff flowid 1:3; tc filter add dev eth0 parent 1: protocol ip u32 match ip dport $MESH_PORT 0xffff flowid 1:3; echo netem-on" >/dev/null
  # sample 40 inner pings to measure observed loss/latency while degraded
  local out
  out="$(ssh_run "$QL_IRAN_HOST" "for i in \$(seq 1 40); do ping -c 1 -W 2 $MESH_HUB_IP 2>/dev/null | grep -oE 'time=[0-9.]+' || echo LOSS; done")"
  local total loss received rtts
  total="$(printf '%s\n' "$out" | grep -c .)"
  loss="$(printf '%s\n' "$out" | grep -c LOSS || true)"
  received=$((total - loss))
  rtts="$(printf '%s\n' "$out" | grep -oE 'time=[0-9.]+' | cut -d= -f2 | python -c '
import sys, statistics
v=[float(x) for x in sys.stdin if x.strip()]
print(f"{statistics.mean(v):.1f}ms mean, {max(v):.1f}ms max, n={len(v)}") if v else print("n/a")')"
  log "[netem10] inner pings: $received/$total ok, loss=$loss ($rtts)"
  local t0; t0="$(epoch)"
  local t_end=$(( $(date +%s) + 45 )) recovered="no"
  while [ "$(date +%s)" -lt "$t_end" ]; do
    sleep 2
    [ "$(inner_ping "$QL_IRAN_HOST" "$MESH_HUB_IP")" = ok ] && recovered=yes && break
  done
  ssh_run "$QL_IRAN_HOST" "tc qdisc del dev eth0 root 2>/dev/null; echo netem-off" >/dev/null
  sleep 2
  local post_loss
  post_loss="$(ssh_run "$QL_IRAN_HOST" "ok=0; for i in \$(seq 1 10); do ping -c 1 -W 2 $MESH_HUB_IP >/dev/null 2>&1 && ok=\$((ok+1)); done; echo \$ok/10")"
  printf '{"test":"netem10","inject_ms":%s,"observed_loss_pct":%s,"observed_rtt":"%s","data_plane_alive_during":%s,"post_removal_ok":"%s"}\n' \
    "$t0" "$(python -c "print(round(100.0*$loss/$total,1))" 2>/dev/null || echo null)" "$rtts" \
    "$([ "$recovered" = yes ] && echo true || echo false)" "$post_loss" >>"$ROWS_FILE"
  log "[netem10] removed; post-removal ping ok: $post_loss"
}

t_blackhole() {
  # tc netem loss 100% scoped to the mesh port (SSH port 22 unaffected).
  # tc instead of nft: co-tenant workloads on the shared test servers wipe
  # foreign nft tables; qdiscs have proven stable.
  log "[blackhole] 100% loss on mesh port via tc netem on iran"
  ssh_run "$QL_IRAN_HOST" "tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root handle 1: prio bands 3; tc qdisc add dev eth0 parent 1:3 handle 30: netem loss 100% limit 200; tc filter add dev eth0 parent 1: protocol ip u32 match ip sport $MESH_PORT 0xffff flowid 1:3; tc filter add dev eth0 parent 1: protocol ip u32 match ip dport $MESH_PORT 0xffff flowid 1:3; echo blackhole-on" >/dev/null
  measure_outage "blackhole" "$QL_IRAN_HOST" "true" "$QL_IRAN_HOST" "tc qdisc del dev eth0 root 2>/dev/null; echo blackhole-off" no
}

# ---------------------------------------------------------------------------

report() {
  python - "$ROWS_FILE" "$RESULT_JSON" "$RESULT_MD" "$QLAB_TS" <<'PYEOF'
import json, sys
rows_file, out_json, out_md, ts = sys.argv[1:5]
rows = [json.loads(l) for l in open(rows_file) if l.strip()]
json.dump(rows, open(out_json, "w"), indent=1)
with open(out_md, "w") as f:
    f.write(f"# Failure tests — {ts}\n\n")
    for r in rows:
        f.write(f"## {r['test']}\n\n")
        for k, v in r.items():
            if k != "test":
                f.write(f"- {k}: `{json.dumps(v) if isinstance(v,(dict,list)) else v}`\n")
        f.write("\n")
print(f"report: {out_md} ({len(rows)} tests)")
PYEOF
}

main() {
  local t
  for t in "${TESTS[@]}"; do
    case "$t" in
      kill-hub)  t_kill_hub ;;
      kill-node) t_kill_node ;;
      netem10)   t_netem10 ;;
      blackhole) t_blackhole ;;
      *) fail "unknown test: $t" ;;
    esac
  done
  report
  rm -f "$ROWS_FILE"
}

main "$@"
