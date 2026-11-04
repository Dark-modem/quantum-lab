#!/usr/bin/env bash
# repair-lab.sh — clean slate for the lab panel state: revoke every agent,
# delete every tunnel, re-enroll both agents fresh (via the panel's PUBLIC
# address — a localhost enrollment poisons the hub transport address).
#
# Run this if enrollment state went bad (e.g. after changing enroll URLs).
# It never touches binaries, units, or the panel credential.
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

panel_api() { # <method> <path> [body]
  local method="$1" path="$2" body="${3:-}" csrf base
  base="$(panel_base)"
  csrf="$(ssh_run "$QL_GERMANY_HOST" "grep gre_csrf $PANEL_COOKIE_JAR_REMOTE 2>/dev/null | awk '{print \$7}'")"
  local extra=""
  [ -n "$body" ] && extra="-d '$body'"
  ssh_run "$QL_GERMANY_HOST" "curl -s -o /tmp/qlab-api-out -w '%{http_code}' -X $method -b $PANEL_COOKIE_JAR_REMOTE -H 'Content-Type: application/json' -H 'X-CSRF-Token: $csrf' $extra http://127.0.0.1:$PANEL_PORT/$base/$path" >/dev/null
  ssh_run "$QL_GERMANY_HOST" "cat /tmp/qlab-api-out 2>/dev/null; rm -f /tmp/qlab-api-out"
}

log "repair: login"
panel_login

log "repair: deleting all tunnels"
local_tunnels="$(panel_api GET "api/agent-tunnels" | python -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(x["id"] for x in d.get("tunnels",[])))' 2>/dev/null || true)"
for tid in $local_tunnels; do
  log "  delete tunnel $tid"
  panel_api DELETE "api/agent-tunnels/$tid" >/dev/null
done
sleep 3

log "repair: revoking all agents"
agents_out="$(panel_api GET "api/agents")"
echo "$agents_out" | python -c '
import json,sys
d=json.load(sys.stdin)
for a in d.get("agents",[]):
    print(a["id"], a.get("status",""))' | while read -r aid st; do
  log "  revoke agent $aid ($st)"
  panel_api POST "api/agents/$aid/revoke" >/dev/null
done

log "repair: fresh enrollment via public URL"
PUB="$(germany_public_ip)"
BASE="$(panel_base)"
for role in iran foreign; do
  tok="$(panel_api POST "api/agents/tokens" "{\"role\":\"$role\",\"label\":\"phase1c-repair\",\"expires_days\":1}" | python -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  [ -n "$tok" ] || { log "ERROR: token mint failed for $role"; exit 1; }
  h="$QL_IRAN_HOST"; name="lab-iran"
  [ "$role" = foreign ] && h="$QL_GERMANY_HOST" && name="lab-germany"
  log "  enroll $name ($h) via http://$PUB:$PANEL_PORT/$BASE"
  ssh_run "$h" "$AGENT_BIN_REMOTE enroll --server 'http://$PUB:$PANEL_PORT/$BASE' --token '$tok' --name '$name'" >/dev/null
  ssh_run "$h" "systemctl restart $AGENT_UNIT"
done

log "repair: waiting for both agents online"
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n="$(panel_api GET "api/agents" | python -c '
import json,sys
d=json.load(sys.stdin)
print(sum(1 for a in d.get("agents",[]) if a.get("status")=="online"))' 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && { log "both agents online"; break; }
  sleep 5
done
panel_api GET "api/agents" | python -m json.tool
log "repair done"
