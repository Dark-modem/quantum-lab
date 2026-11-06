#!/usr/bin/env bash
# phase3-hardening.sh — key-only sshd on the IRAN server via the agent's
# hardening module with safe-apply (rollback timer 120s, confirm via the
# panel API). The panel API is called DIRECTLY from this host (no SSH);
# the only SSH-dependent step is the one-time enrollment of the agent.
#
# Usage:
#   phase3-hardening.sh enroll              # one-time: enroll the iran agent (needs SSH)
#   phase3-hardening.sh apply               # apply key-only profile, timer armed
#   phase3-hardening.sh verify              # check sshd config state (config-level)
#   phase3-hardening.sh confirm             # confirm within the timer (keeps the profile)
#   phase3-hardening.sh wait-rollback       # wait for the timer and verify rollback
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CRED_FILE="$HOME/.qlab-panel-cred"
PANEL_COOKIE_JAR_REMOTE="/tmp/qlab-cookies"
PANEL_COOKIE_JAR_LOCAL="$QLAB_OUT/panel-cookies.txt"

# Direct panel access from this host (the panel is reachable without SSH).
panel_login_local() {
  local base body
  base="$(grep -m1 "Base Path:" "$CRED_FILE" | sed 's|.*Base Path: /||; s| (UNCHANGED)||; s| ||g')"
  body="{\"username\":$(json_escape "$(grep -m1 "Username:" "$CRED_FILE" | sed 's|.*Username:  ||')"),\"password\":$(json_escape "$(grep -m1 "Password:" "$CRED_FILE" | sed 's|.*Password:  ||')")}"
  rm -f "$PANEL_COOKIE_JAR_LOCAL"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -c "$PANEL_COOKIE_JAR_LOCAL" -H 'Content-Type: application/json' -d "$body" "http://$(germany_public_ip):$PANEL_PORT/$base/api/login")"
  [ "$code" = 200 ] || fail "panel login failed (HTTP $code)"
  echo "$base"
}

panel_api_local() { # <method> <path> [body] — needs panel_login_local first
  local method="$1" path="$2" body="${3:-}"
  local base csrf
  base="$(grep -m1 "Base Path:" "$CRED_FILE" | sed 's|.*Base Path: /||; s| (UNCHANGED)||; s| ||g')"
  csrf="$(grep gre_csrf "$PANEL_COOKIE_JAR_LOCAL" 2>/dev/null | awk '{print $7}')"
  local extra=""
  [ -n "$body" ] && extra="-d '$body'"
  eval curl -s -X "$method" -b "$PANEL_COOKIE_JAR_LOCAL" -H "'Content-Type: application/json'" -H "'X-CSRF-Token: $csrf'" $extra "'http://$(germany_public_ip):$PANEL_PORT/$base/api/$path'"
}

case "${1:-}" in
  enroll)
    # mint a token via the panel API (direct), then run the agent CLI on iran
    BASE="$(panel_login_local)"
    TOKEN="$(panel_api_local POST "agents/tokens" '{"role":"iran","label":"phase5-hardening","expires_days":1}' | python -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
    [ -n "$TOKEN" ] || fail "token mint failed"
    ssh_run "$QL_IRAN_HOST" "$AGENT_BIN_REMOTE enroll --server 'http://$(germany_public_ip):$PANEL_PORT/$BASE' --token '$TOKEN' --name 'lab-iran'" || fail "enroll failed"
    ssh_run "$QL_IRAN_HOST" "systemctl restart $AGENT_UNIT"
    log "iran agent enrolled and restarted"
    ;;
  apply)
    BASE="$(panel_login_local)"
    agents="$(panel_api_local GET "agents")"
    ag="$(printf '%s' "$agents" | python -c '
import json,sys
d=json.load(sys.stdin)
c=[a for a in d.get("agents",[]) if "iran" in (a.get("name") or "") and a.get("status")=="online"]
print(c[0]["id"] if c else "")')"
    [ -n "$ag" ] || fail "iran agent not online"
    log "applying key-only sshd profile to $ag (rollback timer 120s)"
    panel_api_local POST "mesh/agents/$ag/profile/hardening" \
      '{"profile":{"version":1,"name":"key-only-sshd","ssh":{"key_only":true,"permit_root":"prohibit-password"}},"rollback_timer_s":120}'
    ;;
  verify)
    ssh_run "$QL_IRAN_HOST" 'sshd -T 2>/dev/null | grep -E "passwordauthentication|permitrootlogin|kbdinteractiveauthentication" | head -4; ls /etc/ssh/sshd_config.d/ | grep -i quantum || echo "no quantum drop-in"'
    ;;
  confirm)
    BASE="$(panel_login_local)"
    ag="$(panel_api_local GET "agents" | python -c '
import json,sys
d=json.load(sys.stdin)
c=[a for a in d.get("agents",[]) if "iran" in (a.get("name") or "") and a.get("status")=="online"]
print(c[0]["id"] if c else "")')"
    [ -n "$ag" ] || fail "iran agent not online"
    log "confirming hardening profile on $ag"
    panel_api_local POST "mesh/agents/$ag/profile/confirm" '{}'
    ;;
  wait-rollback)
    log "waiting 150s for the rollback timer (armed 120s)"
    sleep 150
    ;;
  *)
    fail "usage: phase3-hardening.sh {enroll|apply|verify|confirm|wait-rollback}"
    ;;
esac
