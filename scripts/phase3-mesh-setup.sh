#!/usr/bin/env bash
# phase3-mesh-setup.sh — configure the mesh store via the panel API and push
# the DesiredV2 doc that runs the FRP tunnel between iran and germany:
# datacenters -> servers -> topology(generate, 1 frp slot) -> link agents -> push.
# The Matrix tunnel stays on its frozen v1 flow (already provisioned/running).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CRED_FILE="$HOME/.qlab-panel-cred"
PANEL_COOKIE_JAR_REMOTE="/tmp/qlab-cookies"

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

panel_api() { # <method> <path> [body] -> stdout body
  local method="$1" path="$2" body="${3:-}" csrf base
  base="$(panel_base)"
  csrf="$(ssh_run "$QL_GERMANY_HOST" "grep gre_csrf $PANEL_COOKIE_JAR_REMOTE 2>/dev/null | awk '{print \$7}'")"
  local extra=""
  [ -n "$body" ] && extra="-d '$body'"
  ssh_run "$QL_GERMANY_HOST" "curl -s -X $method -b $PANEL_COOKIE_JAR_REMOTE -H 'Content-Type: application/json' -H 'X-CSRF-Token: $csrf' $extra http://127.0.0.1:$PANEL_PORT/$base/api/$path"
}

log "phase3 mesh setup: login"
panel_login

log "creating datacenters"
dc_iran="$(panel_api POST "mesh/datacenters" '{"name":"lab-iran","kind":"iran","price_coefficient":1}' | tee /tmp/qlab-dc1.json | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
[ -n "$dc_iran" ] || log "dc1 response: $(cat /tmp/qlab-dc1.json 2>/dev/null | head -c 300)"
dc_ger="$(panel_api POST "mesh/datacenters" '{"name":"lab-germany","kind":"foreign","price_coefficient":1}' | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
[ -n "$dc_iran" ] && [ -n "$dc_ger" ] || { log "dc create failed"; exit 1; }
log "dc iran=$dc_iran germany=$dc_ger"

log "creating servers"
srv_iran="$(panel_api POST "mesh/servers" "{\"name\":\"lab-iran\",\"role\":\"iran\",\"datacenter_id\":$dc_iran,\"address\":\"185.226.119.74\"}" | tee /tmp/qlab-srv1.json | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
[ -n "$srv_iran" ] || log "server1 response: $(head -c 300 /tmp/qlab-srv1.json 2>/dev/null)"
srv_ger="$(panel_api POST "mesh/servers" "{\"name\":\"lab-germany\",\"role\":\"foreign\",\"datacenter_id\":$dc_ger,\"address\":\"$(germany_public_ip)\"}" | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
[ -n "$srv_iran" ] && [ -n "$srv_ger" ] || { log "server create failed"; exit 1; }
log "servers iran=$srv_iran germany=$srv_ger"

log "generating topology (1 frp slot per pair)"
TOKEN="$(ssh_run "$QL_IRAN_HOST" "tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24")"
PARAMS=$(cat <<EOF
{"server_side":"lab-germany","version":"0.61.1","artifact":"frp-0.61.1-linux-{arch}.tar.gz","sha256_amd64":"bff260b68ca7b1461182a46c4f34e9709ba32764eed30a15dd94ac97f50a2c40","sha256_arm64":"af6366f2b43920ebfe6235dba6060770399ed1fb18601e5818552bd46a7621f8","signature_amd64":"pxgT59M7JKd7qy7RMaF9N+FjdGjc5DSzaPBLuSIGVWaYLwnb/B3OlD7pUuBpMj4M/vvoyLoG3nQGuKc+UFzXDA==","signature_arm64":"v1ZdCkMxQSkhBfpoAkkLYM9d4pgMEqhBtERS0Aq53oSlTSh43UaKoBjcA+B6GRvrkfhOgqFt6L+AKMakSIqwCw==","server_addr":"$(germany_public_ip)","server_port":7000,"token":"$TOKEN","remote_port":34001,"local_addr":"127.0.0.1","local_port":5201,"dashboard_port":17500,"allow_port_min":34000,"allow_port_max":34010}
EOF
)
gen="$(panel_api POST "mesh/topologies/generate" "{\"name\":\"lab-topo\",\"iran_servers\":[$srv_iran],\"foreign_servers\":[$srv_ger],\"tunnels_per_pair\":1,\"engines\":[\"frp\"],\"engine_params\":[$PARAMS],\"enabled\":true}")"
echo "$gen" | head -c 400; echo
topo_id="$(printf '%s' "$gen" | python -c 'import json,sys; print(json.load(sys.stdin).get("topology_id",""))' 2>/dev/null)"
[ -n "$topo_id" ] || { log "topology generate failed"; exit 1; }
log "topology=$topo_id"

log "linking agents to servers"
agents_json="$(panel_api GET "agents")"
ag_iran="$(printf '%s' "$agents_json" | python -c '
import json,sys
d=json.load(sys.stdin)
c=[a for a in d.get("agents",[]) if "iran" in (a.get("name") or "") and a.get("status")=="online"]
c.sort(key=lambda a: 0 if a.get("status")=="online" else 1)
print(c[0]["id"] if c else "")' 2>/dev/null)"
ag_ger="$(printf '%s' "$agents_json" | python -c '
import json,sys
d=json.load(sys.stdin)
c=[a for a in d.get("agents",[]) if "germany" in (a.get("name") or "") and a.get("status")=="online"]
c.sort(key=lambda a: 0 if a.get("status")=="online" else 1)
print(c[0]["id"] if c else "")' 2>/dev/null)"
[ -n "$ag_iran" ] && [ -n "$ag_ger" ] || { log "agent ids not resolved: iran=$ag_iran ger=$ag_ger"; exit 1; }
panel_api POST "mesh/agents/$ag_iran/link" "{\"server_id\":$srv_iran}" >/dev/null
panel_api POST "mesh/agents/$ag_ger/link" "{\"server_id\":$srv_ger}" >/dev/null
log "linked $ag_iran->$srv_iran, $ag_ger->$srv_ger"

log "pushing DesiredV2 to both agents"
panel_api POST "mesh/agents/$ag_ger/push" >/dev/null
panel_api POST "mesh/agents/$ag_iran/push" >/dev/null
log "push done"
