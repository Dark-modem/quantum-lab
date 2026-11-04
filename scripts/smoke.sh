#!/usr/bin/env bash
# smoke.sh — end-to-end lab smoke test against the deployed panel/agents.
#
#   smoke.sh            run all steps
#   smoke.sh <step>...  run selected steps (panel-login enroll heartbeat
#                       desired-state panel-death)
#
# Steps:
#   panel-login     verify admin login works (no credentials are printed)
#   enroll          mint enroll tokens, enroll both agents, verify agents appear
#   heartbeat       wait until both agents report a healthy WS + state
#   desired-state   create one Matrix tunnel via /api/agent-tunnels, wait until
#                   active, verify mesh IPs respond and units are active
#   panel-death     stop the panel, verify tunnels keep running, restart panel,
#                   verify agents reconnect; record timings
#
# All results go to results/smoke-<date>.md (no secrets; the panel password is
# never printed — only the word PASS/FAIL).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

STEPS=("${@:-panel-login enroll heartbeat desired-state panel-death}")
RESULT_MD="$QLAB_RESULTS/smoke-$QLAB_TS.md"
RESULT_JSON="$QLAB_RESULTS/smoke-$QLAB_TS.json"
mkdir -p "$QLAB_RESULTS"

CRED_FILE="$HOME/.qlab-panel-cred"
PASS=0; FAILS=0
declare -a CHECKS

check() { # check <name> <ok:0|1> <detail>
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); CHECKS+=("PASS  $name $detail");
    log "PASS $name $detail"
  else FAILS=$((FAILS+1)); CHECKS+=("FAIL  $name $detail");
    log "FAIL $name $detail"
  fi
}

# ---------------------------------------------------------------------------
# panel access helpers (executed ON the germany server via curl; no secrets
# leave the servers except the one-time credential display at report time)
# ---------------------------------------------------------------------------

panel_base() { grep -m1 "Base Path:" "$CRED_FILE" | sed 's|.*Base Path: /||; s| (UNCHANGED)||; s| ||g'; }
panel_user() { grep -m1 "Username:" "$CRED_FILE" | sed 's|.*Username:  ||'; }
panel_pass() { grep -m1 "Password:" "$CRED_FILE" | sed 's|.*Password:  ||'; }

# panel_api <method> <path> [json-body] — runs on germany, uses session cookies.
# Globals set: PA_CODE (http code), PA_OUT (body)
panel_api() {
  local method="$1" path="$2" body="${3:-}"
  local base csrf
  base="$(panel_base)"
  csrf="$(ssh_run "$QL_GERMANY_HOST" "grep gre_csrf $PANEL_COOKIE_JAR_REMOTE 2>/dev/null | awk '{print \$7}'")"
  local extra=""
  [ -n "$body" ] && extra="-d '$body'"
  PA_CODE="$(ssh_run "$QL_GERMANY_HOST" "curl -s -o /tmp/qlab-api-out -w '%{http_code}' -X $method -b $PANEL_COOKIE_JAR_REMOTE -H 'Content-Type: application/json' -H 'X-CSRF-Token: $csrf' $extra http://127.0.0.1:$PANEL_PORT/$base/$path")"
  PA_OUT="$(ssh_run "$QL_GERMANY_HOST" "cat /tmp/qlab-api-out 2>/dev/null; rm -f /tmp/qlab-api-out")"
}

panel_login() {
  local base; base="$(panel_base)"
  ssh_run "$QL_GERMANY_HOST" "rm -f $PANEL_COOKIE_JAR_REMOTE"
  local body="{\"username\":$(json_escape "$(panel_user)"),\"password\":$(json_escape "$(panel_pass)")}"
  # pass the body via stdin to keep it out of remote argv
  PA_CODE="$(printf '%s' "$body" | ssh_run "$QL_GERMANY_HOST" "curl -s -o /tmp/qlab-login-out -w '%{http_code}' -X POST -b $PANEL_COOKIE_JAR_REMOTE -c $PANEL_COOKIE_JAR_REMOTE -H 'Content-Type: application/json' -d @- http://127.0.0.1:$PANEL_PORT/$base/api/login")"
  PA_OUT="$(ssh_run "$QL_GERMANY_HOST" "cat /tmp/qlab-login-out; rm -f /tmp/qlab-login-out")"
  PA_CSRF="$(ssh_run "$QL_GERMANY_HOST" "grep gre_csrf $PANEL_COOKIE_JAR_REMOTE 2>/dev/null | awk '{print \$7}'")"
}

# ---------------------------------------------------------------------------
# steps
# ---------------------------------------------------------------------------

step_panel_login() {
  log "step: panel-login"
  panel_login
  local ok=0 detail="http=$PA_CODE csrf=${PA_CSRF:+present}"
  case "$PA_CODE" in 200) ok=1 ;; esac
  check "panel-login" "$ok" "$detail"
}

step_enroll() {
  log "step: enroll"
  panel_login
  # mint one token per role
  for role in iran foreign; do
    panel_api POST "api/agents/tokens" "{\"role\":\"$role\",\"label\":\"phase1c-lab\",\"expires_days\":1}"
    local tok
    tok="$(printf '%s' "$PA_OUT" | python -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
    if [ -z "$tok" ]; then check "mint-token-$role" 0 "response=$PA_OUT"; return; fi
    log "[$role] enroll token minted (${#tok} chars)"
    local h="$QL_IRAN_HOST" name="lab-iran"
    [ "$role" = foreign ] && h="$QL_GERMANY_HOST" && name="lab-germany"
    local url="http://91.107.179.252:$PANEL_PORT/$(panel_base)"
    [ "$role" = foreign ] && url="http://127.0.0.1:$PANEL_PORT/$(panel_base)"
    if ssh_run "$h" "$AGENT_BIN_REMOTE enroll --server '$url' --token '$tok' --name '$name'"; then
      check "enroll-$role" 1 "$h"
    else
      check "enroll-$role" 0 "$h"
    fi
    ssh_run "$h" "systemctl restart $AGENT_UNIT"
  done
}

step_heartbeat() {
  log "step: heartbeat"
  panel_login
  local deadline=$(( $(date +%s) + 120 )) found=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    panel_api GET "api/agents"
    found="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
agents=d if isinstance(d,list) else d.get("agents",[])
for a in agents:
    print(a.get("id",""),a.get("name",""),a.get("status",""),a.get("connected",""),a.get("last_seen",a.get("last_heartbeat","")))
' 2>/dev/null)"
    local n; n="$(printf '%s\n' "$found" | grep -c . || true)"
    if [ "$n" -ge 2 ]; then
      check "agents-visible" 1 "count=$n"
      log "agents: $found"
      return 0
    fi
    sleep 5
  done
  check "agents-visible" 0 "count=$n (last=$found)"
}

step_desired_state() {
  log "step: desired-state"
  panel_login
  panel_api GET "api/agents"
  local hub_id node_id
  hub_id="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
d=json.load(sys.stdin); agents=d if isinstance(d,list) else d.get("agents",[])
print([a["id"] for a in agents if "germany" in a.get("name","")][0])' 2>/dev/null)"
  node_id="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
d=json.load(sys.stdin); agents=d if isinstance(d,list) else d.get("agents",[])
print([a["id"] for a in agents if "iran" in a.get("name","")][0])' 2>/dev/null)"
  if [ -z "$hub_id" ] || [ -z "$node_id" ]; then
    check "resolve-agent-ids" 0 "hub=$hub_id node=$node_id"; return
  fi
  check "resolve-agent-ids" 1 "hub=$hub_id node=$node_id"

  # create the tunnel (idempotent-ish: reuse existing lab tunnel if present)
  panel_api GET "api/agent-tunnels"
  local existing
  existing="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
d=json.load(sys.stdin)
t=d.get("tunnels",d if isinstance(d,list) else [])
print([x["id"] for x in t if x.get("name")=="lab-matrix"][0])' 2>/dev/null || true)"
  local tid="$existing"
  if [ -z "$tid" ]; then
    panel_api POST "api/agent-tunnels" "{\"name\":\"lab-matrix\",\"hub_agent_id\":\"$hub_id\",\"node_agent_id\":\"$node_id\",\"family\":\"ipv4\",\"port\":$MESH_PORT,\"ports\":[$IPERF_PORT]}"
    tid="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
d=json.load(sys.stdin); print(d.get("tunnel",{}).get("id",""))' 2>/dev/null)"
    [ -n "$tid" ] && check "tunnel-create" 1 "id=$tid" || check "tunnel-create" 0 "resp=$PA_OUT"
  else
    check "tunnel-create" 1 "id=$tid (already existed)"
  fi

  # wait until active
  local deadline=$(( $(date +%s) + 180 )) state="?"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    panel_api GET "api/agent-tunnels"
    state="$(printf '%s' "$PA_OUT" | python -c '
import json,sys
d=json.load(sys.stdin)
t=d.get("tunnels",d if isinstance(d,list) else [])
print([x.get("state","?") for x in t if x.get("id")=="'"$tid"'"][0])' 2>/dev/null)"
    [ "$state" = "active" ] && break
    [ "$state" = "error" ] && break
    sleep 6
  done
  check "tunnel-active" "$([ "$state" = active ] && echo 1 || echo 0)" "id=$tid state=$state"

  # mesh verification: qmx iface + mesh IP ping + unit active
  local if_iran if_ger ping_iran ping_ger unit_iran unit_ger
  if_iran="$(ssh_run "$QL_IRAN_HOST" "ip -o link show | grep -c 'qmx' || true")"
  if_ger="$(ssh_run "$QL_GERMANY_HOST" "ip -o link show | grep -c 'qmx' || true")"
  ping_iran="$(ssh_run "$QL_IRAN_HOST" "ping -c 3 -W 3 $MESH_HUB_IP >/dev/null && echo yes || echo no")"
  ping_ger="$(ssh_run "$QL_GERMANY_HOST" "ping -c 3 -W 3 $MESH_NODE_IP >/dev/null && echo yes || echo no")"
  unit_iran="$(ssh_run "$QL_IRAN_HOST" "systemctl is-active quantum-matrix.service || true")"
  unit_ger="$(ssh_run "$QL_GERMANY_HOST" "systemctl is-active quantum-matrix.service || true")"
  check "mesh-iface-iran" "$([ "$if_iran" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" "qmx_ifaces=$if_iran"
  check "mesh-iface-germany" "$([ "$if_ger" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" "qmx_ifaces=$if_ger"
  check "mesh-ping-iran-to-hub" "$([ "$ping_iran" = yes ] && echo 1 || echo 0)" ""
  check "mesh-ping-germany-to-node" "$([ "$ping_ger" = yes ] && echo 1 || echo 0)" ""
  check "matrix-unit-iran" "$([ "$unit_iran" = active ] && echo 1 || echo 0)" "$unit_iran"
  check "matrix-unit-germany" "$([ "$unit_ger" = active ] && echo 1 || echo 0)" "$unit_ger"

  # desired state acked on both agents?
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    local ds
    ds="$(ssh_run "$h" "python3 -c 'import json;d=json.load(open(\"/etc/quantum-agent/agent-state.json\"));print(d.get(\"desired_status\",\"\"),d.get(\"applied_revision\",\"\"))' 2>/dev/null || echo none")"
    check "desired-acked-$h" "$(printf '%s' "$ds" | grep -q applied && echo 1 || echo 0)" "$ds"
  done
}

step_panel_death() {
  log "step: panel-death"
  # pre-check tunnel is alive
  local pre
  pre="$(ssh_run "$QL_IRAN_HOST" "ping -c 2 -W 3 $MESH_HUB_IP >/dev/null && echo yes || echo no")"
  [ "$pre" = yes ] && check "panel-death-precondition" 1 || { check "panel-death-precondition" 0 "mesh down before test"; return; }

  # stop the panel
  local t0; t0="$(date +%s)"
  ssh_run "$QL_GERMANY_HOST" "systemctl stop $PANEL_UNIT"
  sleep 10
  local during_ping during_unit
  during_ping="$(ssh_run "$QL_IRAN_HOST" "ping -c 3 -W 3 $MESH_HUB_IP >/dev/null && echo yes || echo no")"
  during_unit="$(ssh_run "$QL_GERMANY_HOST" "systemctl is-active quantum-matrix.service || true")"
  check "tunnel-survives-panel-stop-ping" "$([ "$during_ping" = yes ] && echo 1 || echo 0)" ""
  check "tunnel-survives-panel-stop-unit" "$([ "$during_unit" = active ] && echo 1 || echo 0)" "$during_unit"

  # short iperf3 through mesh while panel is dead
  ssh_run "$QL_GERMANY_HOST" "timeout 20 iperf3 -s -1 -B $MESH_HUB_IP -p $IPERF_PORT >/dev/null 2>&1 &"
  sleep 1
  local ipf
  ipf="$(ssh_run "$QL_IRAN_HOST" "timeout 25 iperf3 -c $MESH_HUB_IP -p $IPERF_PORT -t 5 2>/dev/null | tail -n 3 | grep -oE '[0-9.]+ [KMG]bits/sec' | tail -1")"
  check "tunnel-iperf-while-panel-dead" "$([ -n "$ipf" ] && echo 1 || echo 0)" "rate=$ipf"

  # restart the panel; measure agent reconnect
  local t1; t1="$(date +%s)"
  ssh_run "$QL_GERMANY_HOST" "systemctl start $PANEL_UNIT"
  local deadline=$(( $(date +%s) + 120 )) reconnected=no
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ws
    ws="$(ssh_run "$QL_IRAN_HOST" "python3 -c 'import json;d=json.load(open(\"/etc/quantum-agent/agent-state.json\"));ws=d.get(\"ws\") or {};print(ws.get(\"connected\"))' 2>/dev/null || echo unknown")"
    if [ "$ws" = "True" ] || [ "$ws" = "true" ]; then reconnected=yes; break; fi
    sleep 5
  done
  local t2; t2="$(date +%s)"
  check "agents-reconnect-after-panel-restart" "$([ "$reconnected" = yes ] && echo 1 || echo 0)" "took=$((t2-t1))s"
  local post
  post="$(ssh_run "$QL_IRAN_HOST" "ping -c 3 -W 3 $MESH_HUB_IP >/dev/null && echo yes || echo no")"
  check "tunnel-still-alive-after-restart" "$([ "$post" = yes ] && echo 1 || echo 0)" ""
}

# ---------------------------------------------------------------------------

report() {
  {
    echo "# Smoke results — $QLAB_TS"
    echo
    for c in "${CHECKS[@]}"; do echo "- $c"; done
    echo
    echo "Summary: $PASS passed, $FAILS failed"
  } >"$RESULT_MD"
  printf '{"date":"%s","pass":%d,"fails":%d,"checks":[%s]}\n' "$QLAB_TS" "$PASS" "$FAILS" \
    "$(python - "$RESULT_MD" <<'PYEOF'
import sys
lines=[l.strip().lstrip('- ') for l in open(sys.argv[1]) if l.strip().startswith('- PASS') or l.strip().startswith('- FAIL')]
import json
out=[]
for l in lines:
    parts=l.split(' ',2)
    out.append({"verdict":parts[0],"name":parts[1],"detail":parts[2] if len(parts)>2 else ""})
print(json.dumps(",".join(json.dumps(o) for o in out)))
PYEOF
)" >"$RESULT_JSON"
  log "results: $RESULT_MD / $RESULT_JSON"
}

PANEL_COOKIE_JAR_REMOTE="/tmp/qlab-cookies"
PANEL_COOKIE_JAR=""  # cookies handled remotely only

main() {
  local s
  for s in "${STEPS[@]}"; do
    case "$s" in
      panel-login)   step_panel_login ;;
      enroll)        step_enroll ;;
      heartbeat)     step_heartbeat ;;
      desired-state) step_desired_state ;;
      panel-death)   step_panel_death ;;
      *) fail "unknown step: $s" ;;
    esac
  done
  report
  [ "$FAILS" -eq 0 ] && log "SMOKE OK ($PASS checks passed)" || log "SMOKE FAILED ($FAILS failing checks)"
  return "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
}

main "$@"
