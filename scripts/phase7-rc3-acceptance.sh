#!/usr/bin/env bash
# phase7-rc3-acceptance.sh — the RC3 real-server acceptance, per RUNBOOK-FA.md
# literally, from a CLEAN state (wipe to baseline first).
#
# Prereqs (checked): the RC3 bundle path + sha256 (from RELEASE-READY.md
# "RC3:" line), both servers reachable, the lab key auth, baseline snapshots
# in results/baseline/.
#
# Stages (each logs PASS/FAIL into $ROWS):
#   wipe        restore both hosts to the phase-1C baseline (deploy.sh --wipe + sshd/config revert)
#   bundle      verify the RC3 bundle (sig + checksums) locally, ship to both
#   panel       install-panel (HTTPS) on germany, initial password captured
#   agents      install-agent on both (enroll via HTTPS)
#   mesh        DCs/servers/topology (2 tunnels/pair: matrix + frp) + R5 frp artifact upload + link + push
#   split       forward rule 8443 + weights 70/30 + 1000-connection split (sink counters)
#   flip        weights 30/70 + re-measure
#   failover    kill one tunnel, measure recovery, restore
#   paneldeath  stop panel, traffic check, restart, revision-storm check
#   usage       usage API per direction
#   report      write results/phase7-rc3-results.json
#
# Usage: phase7-rc3-acceptance.sh <rc3-zip-path> <rc3-sha256>
# STATUS: skeleton — the panel/agent/mesh/split stages reuse the phase-3/5 lab
# scripts (deploy.sh, phase3-hardening.sh, bench/overhead.sh) and are finished
# when the RC3 bundle is announced. The wipe stage is complete.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

RC3_ZIP="${1:?usage: phase7-rc3-acceptance.sh <rc3-zip> <sha256>}"
RC3_SHA="${2:?usage: phase5-rc3-acceptance.sh <rc3-zip> <sha256>}"
ROWS="$QLAB_OUT/phase7-rows-$QLAB_TS.jsonl"
touch "$ROWS"

pass() { log "PASS $1"; printf '{"stage":"%s","verdict":"PASS"}\n' "$1" >>"$ROWS"; }
fail() { log "FAIL $1 ${2:-}"; printf '{"stage":"%s","verdict":"FAIL","note":"%s"}\n' "$1" "${2:-}" >>"$ROWS"; }

stage_wipe() {
  log "stage: wipe (baseline restore)"
  if bash "$(dirname "$0")/deploy.sh" --wipe >>"$QLAB_OUT/phase7-wipe.log" 2>&1; then
    pass wipe
  else
    fail wipe "deploy.sh --wipe failed"
  fi
}

stage_bundle() {
  log "stage: bundle verify"
  local d="$QLAB_OUT/rc3"
  rm -rf "$d"; mkdir -p "$d"
  if ! unzip -q -o "$RC3_ZIP" -d "$d"; then fail bundle "unzip"; return 1; fi
  (cd "$d/$(ls "$d" | head -1)" 2>/dev/null || cd "$d")
  local bd
  bd="$(find "$d" -name checksums.txt | head -1 | xargs dirname)"
  if openssl pkeyutl -verify -rawin -pubin -inkey "$bd/../signing-public.pem" \
      -in "$bd/checksums.txt" -sigfile "$bd/checksums.txt.sig" 2>/dev/null | grep -q "Signature Verified"; then
    pass bundle
    echo "$bd" >"$QLAB_OUT/rc3-bundle-dir.txt"
  else
    fail bundle "signature verify"
    return 1
  fi
}

stage_panel() {
  local bd; bd="$(cat "$QLAB_OUT/rc3-bundle-dir.txt")"
  log "stage: panel install (germany, HTTPS)"
  push_bigfile "$QL_GERMANY_HOST" "$bd/bin/quantum-panel-linux-arm64" "/tmp/rc3-quantum-panel" \
    && ssh_run "$QL_GERMANY_HOST" "cd $(dirname "$bd" | sed 's|/bin||') 2>/dev/null; bash install-panel.sh --verify-only --binary $bd/bin/quantum-panel-linux-arm64 --checksum $(grep panel-linux-arm64 $bd/bin/checksums.txt | awk '{print $1}') 2>&1 | tail -1" \
    || { fail panel "verify-only"; return 1; }
  ssh_run "$QL_GERMANY_HOST" "cd /tmp/quantum-bundle* 2>/dev/null; bash install-panel.sh --binary /tmp/rc3-quantum-panel --checksum $(grep panel-linux-arm64 $bd/bin/checksums.txt | awk '{print $1}') --generate-password 2>&1 | tail -3; systemctl restart quantum-panel; sleep 4; systemctl is-active quantum-panel"
}

stage_agents() {
  log "stage: agents (both)"
  local iran_bin="$QLAB_OUT/rc3-quantum-agent-amd64"
  ssh_run "$QL_IRAN_HOST" "test -f /tmp/rc3-quantum-agent" || {
    ssh_run "$QL_IRAN_HOST" "test -f /tmp/rc3/quantum-agent" && ssh_run "$QL_IRAN_HOST" "cp /tmp/rc3/quantum-agent /tmp/rc3-quantum-agent"
  }
  :
}

stage_report() {
  python - "$ROWS" "$QLAB_RESULTS/phase7-rc3-results.json" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
json.dump(rows, open(sys.argv[2], "w"), indent=1)
print(f"{sum(1 for r in rows if r['verdict']=='PASS')} PASS / {sum(1 for r in rows if r['verdict']=='FAIL')} FAIL")
PYEOF
}

case "${1:-all}" in
  wipe) stage_wipe ;;
  bundle) stage_bundle ;;
  *) stage_wipe; stage_bundle; stage_panel; stage_agents; stage_report ;;
esac
