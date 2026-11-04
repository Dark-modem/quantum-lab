#!/usr/bin/env bash
# capture-baseline.sh — snapshot the pre-touch OS state of a test server so it
# can be restored later. Text only; committed to the repo. No secrets.
# Usage: capture-baseline.sh <ssh-alias> <results-subdir-name>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ALIAS="${1:?usage: capture-baseline.sh <ssh-alias> <name>}"
NAME="${2:?usage: capture-baseline.sh <ssh-alias> <name>}"
DIR="$QLAB_RESULTS/baseline/$NAME"
mkdir -p "$DIR"

snap() { # snap <filename> <remote-command>
  local f="$DIR/$1"
  local err="$DIR/$1.stderr"
  shift
  log "capturing $f"
  ssh_run "$ALIAS" "$*" >"$f" 2>"$err" || log "WARN: $1 had errors (see .stderr)"
}

snap 00-os.txt          'cat /etc/os-release; uname -a; uptime; hostnamectl 2>/dev/null'
snap 01-packages.txt    'dpkg-query -W -f="${binary:Package}\t${Version}\n" 2>/dev/null; echo ---MANUAL---; apt-mark showmanual 2>/dev/null'
snap 02-ufw.txt         'ufw status verbose 2>&1; echo ---; ufw app list 2>&1'
snap 03-sshd-config.txt 'grep -vE "^#" /etc/ssh/sshd_config 2>/dev/null; echo ---DD---; for f in /etc/ssh/sshd_config.d/*; do echo "== $f"; cat "$f"; done 2>/dev/null; echo ---EFFECTIVE---; sshd -T 2>/dev/null'
snap 04-firewall.txt    'nft list ruleset 2>/dev/null; echo ---IPT4---; iptables-save 2>/dev/null; echo ---IPT6---; ip6tables-save 2>/dev/null'
snap 05-systemd.txt     'systemctl list-unit-files 2>/dev/null; echo ---RUNNING---; systemctl list-units --type=service --state=running --no-pager 2>/dev/null'
snap 06-listeners.txt   'ss -tulpn 2>/dev/null'
snap 07-sysctl.txt      'cat /etc/sysctl.conf 2>/dev/null; echo ---DD---; for f in /etc/sysctl.d/*; do echo "== $f"; cat "$f"; done 2>/dev/null; echo ---LIVE---; sysctl -a 2>/dev/null'
snap 08-network.txt     'ip -br addr; echo ---; ip route show table all 2>/dev/null; echo ---LINK---; ip -br link; echo ---QDISC---; tc qdisc show 2>/dev/null; echo ---PROCNETDEV---; cat /proc/net/dev'
snap 09-root-ssh.txt    'crontab -l 2>&1; echo ---AK---; cat /root/.ssh/authorized_keys 2>/dev/null; echo ---DIR---; ls -la /root/.ssh 2>/dev/null'
snap 10-tinc-leftover.txt 'ls -laR /etc/tinc 2>/dev/null | head -100'
snap 11-resolv-dns.txt  'cat /etc/resolv.conf; echo ---; resolvectl status 2>/dev/null | head -40'

# Fingerprint for later drift comparison.
snap 12-fingerprint.txt 'dpkg-query -W -f="${binary:Package}=${Version}\n" 2>/dev/null | md5sum; ls /etc/ssh/sshd_config.d/ 2>/dev/null | md5sum; nft list ruleset 2>/dev/null | md5sum; systemctl list-unit-files --state=enabled 2>/dev/null | md5sum'

log "baseline for $NAME captured into $DIR"
log "NOTE: authorized_keys will gain one quantum-lab-phase1c key after this snapshot (documented in results/baseline/KEY-INSTALL.md)"
