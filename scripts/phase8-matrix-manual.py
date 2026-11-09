#!/usr/bin/env python3
# phase8-matrix-manual.py — the remaining phase-8 night phases, run manually
# after the detached job crashed (mktime bug in frp_kill_recovery):
#   failover (frp kill + 30 s scoped blackhole + matrix kill) and the
#   engine matrix (matrix/frp/backhaul: iperf3 both directions through the
#   balancer + same-window underlay baseline, kill + blackhole recovery,
#   idle RSS/CPU). Writes results/phase8-night-manual.json + commits.

import json
import os
import re
import subprocess
import time

HOME = os.path.expanduser("~")
LAB = os.path.join(HOME, "Downloads", "Quantum", "01-REPOSITORIES", "quantum-lab")
RESULTS = os.path.join(LAB, "results")
COOKIE = os.path.join(LAB, "out", "panel-https-cookies.txt")
PANEL = "91.107.179.252"
IRAN = "qlab-iran"
GER = "qlab-germany"
LISTEN = 8202  # the route-open measurement port (8443 blocked)

out_lines = []


def log(m):
    line = time.strftime("%H:%M:%S") + " " + str(m)
    out_lines.append(line)
    print(line, flush=True)


def read_cred():
    user = pw = base = None
    with open(os.path.join(HOME, ".qlab-panel-cred"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("Username:"):
                user = line.split(":", 1)[1].strip()
            elif line.startswith("Password:"):
                pw = line.split(":", 1)[1].strip()
            elif line.startswith("Base Path:"):
                base = line.split(":", 1)[1].strip().split(" ")[0].strip("/")
    return user, pw, base


CSRF = [None]


def login():
    user, pw, base = read_cred()
    r = subprocess.run(["curl", "-sk", "-c", COOKIE, "-X", "POST",
                        "-H", "Content-Type: application/json",
                        "-d", json.dumps({"username": user, "password": pw}),
                        f"https://{PANEL}:7443/{base}/api/login"],
                       capture_output=True, text=True, timeout=60)
    with open(COOKIE, encoding="utf-8") as fh:
        for line in fh:
            if "csrf" in line.lower():
                CSRF[0] = line.split()[-1]
    return "ok" in r.stdout


def api(method, path, body=None):
    user, pw, base = read_cred()
    cmd = ["curl", "-sk", "-b", COOKIE, "-H", f"X-CSRF-Token: {CSRF[0]}",
           "-H", "Content-Type: application/json", "-X", method,
           f"https://{PANEL}:7443/{base}/api/{path}", "--max-time", "60"]
    if body:
        cmd += ["-d", json.dumps(body)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    return r.stdout.strip()


def ssh(host, cmd, timeout=90):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                        "-o", "ConnectTimeout=30", host, cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def set_w(tid, w):
    api("POST", "mesh/topologies/1/weights",
        {"local_server_id": 1, "remote_server_id": 2, "tunnel_id": tid, "weight": w})


def push():
    for ag in ("agt_5108f8bafd60", "agt_96dc286ce762"):
        api("POST", f"mesh/agents/{ag}/push")


def engine_runtime():
    d = api("GET", "mesh/agents")
    try:
        j = json.loads(d)
    except Exception:
        return {}
    rt = {}
    for a in j.get("agents", []):
        for t in a.get("runtime") or []:
            rt[t["engine"]] = t
    return rt


def iperf3(direction, port, secs=10):
    flag = "-R " if direction == "down" else ""
    out = ssh(IRAN, f"iperf3 -J {flag}-c {PANEL} -p {port} -t {secs} -O 2 --connect-timeout 8000",
              timeout=secs + 60)
    try:
        j = json.loads(out)
        end = j.get("end", {})
        key = "sum_received" if direction == "down" else "sum_sent"
        s = end.get(key) or end.get("sum_sent") or end.get("sum_received") or {}
        return {"bps": s.get("bits_per_second", 0), "retransmits": s.get("retransmits", 0), "ok": True}
    except Exception:
        return {"ok": False, "raw": out[:150]}


def kill_recover(host, pkill, port_check, label):
    t0 = time.monotonic()
    ssh(host, pkill)
    rec = None
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        n = ssh(host, port_check)
        if n and n.strip() not in ("", "0"):
            rec = round(time.monotonic() - t0, 1)
            break
        time.sleep(3)
    log(f"{label}: recover_s={rec}")
    return {"recover_s": rec}


def blackhole_recover(port, label):
    src = "185.226.119.74"
    t0 = time.monotonic()
    ssh(GER, f"iptables -I INPUT -p tcp --dport {port} -s {src} -j DROP")
    time.sleep(30)
    ssh(GER, f"iptables -D INPUT -p tcp --dport {port} -s {src} -j DROP")
    rec = None
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        n = ssh(GER, f"ss -tn state established '( sport = :{port} )' | wc -l")
        rt = engine_runtime()
        if rt.get(label, {}).get("up") or (n and int(n) > 1):
            rec = round(time.monotonic() - t0, 1)
            break
        time.sleep(3)
    left = ssh(GER, f"iptables -S INPUT | grep -c 'dport {port}' || true")
    log(f"{label} blackhole: recover_s={rec} leftover={left}")
    return {"recover_s": rec, "leftover_rules": left}


def main():
    assert login(), "login failed"
    res = {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "engines": {}, "failover": {}}

    ssh(IRAN, "systemctl stop frp-sink; pkill -x iperf3; iperf3 -s -p 8443 -D; iperf3 -s -p 8202 -D")
    ssh(GER, "pkill -x iperf3; iperf3 -s -p 5201 -D")

    tunnel_of = {"matrix": 1, "frp": 2, "backhaul": 3}
    carriers = {"matrix": 2097, "frp": 7500, "backhaul": 8302}
    procs = {"matrix": "tincd", "frp": "frps", "backhaul": "backhaul"}
    ports = {"matrix": 2097, "frp": 8201, "backhaul": 8303}

    for eng in ("matrix", "frp", "backhaul"):
        entry = {}
        for e2, tid in tunnel_of.items():
            set_w(tid, 100 if e2 == eng else 0)
        push()
        time.sleep(8)
        rt = engine_runtime()
        entry["up_before"] = rt.get(eng, {}).get("up")
        entry["nft"] = ssh(GER, "nft list chain ip quantum-fwd fw_fw_2_tcp | grep dport")
        entry["iperf_up"] = iperf3("up", LISTEN)
        entry["iperf_down"] = iperf3("down", LISTEN)
        entry["underlay_up"] = iperf3("up", 5201)
        entry["underlay_down"] = iperf3("down", 5201)
        entry["usage"] = api("GET", "mesh/usage?topology_id=1")
        entry["kill"] = kill_recover(GER, f"pkill -9 -x {procs[eng]}",
                                     f"ss -tlnp | grep -c ':{ports[eng]} '", f"{eng} kill")
        entry["blackhole"] = blackhole_recover(carriers[eng], eng)
        time.sleep(20)
        entry["idle_ps"] = ssh(GER, f"ps -o pid,comm,rss,pcpu -C {procs[eng]} --no-headers | head -3")
        time.sleep(30)
        entry["idle_ps_after"] = ssh(GER, f"ps -o pid,comm,rss,pcpu -C {procs[eng]} --no-headers | head -3")
        res["engines"][eng] = entry
        log(f"engine {eng}: up={entry['up_before']} iperf_up={entry['iperf_up'].get('bps',0)/1e6:.1f}Mb/s "
            f"down={entry['iperf_down'].get('bps',0)/1e6:.1f}Mb/s underlay_up={entry['underlay_up'].get('bps',0)/1e6:.1f}Mb/s")

    # restore weights
    set_w(1, 70)
    set_w(2, 30)
    set_w(3, 0)
    push()

    # failover numbers (frp kill already exercised; redo cleanly + matrix)
    res["failover"]["frp_kill"] = kill_recover(GER, "pkill -9 -x frps",
                                               "ss -tlnp | grep -c ':8201 '", "frp kill(final)")
    res["failover"]["frp_blackhole"] = blackhole_recover(7500, "frp")
    res["failover"]["matrix_kill"] = kill_recover(IRAN, "pkill -9 -x tincd",
                                                  "ping -c 1 -W 2 10.254.231.1 >/dev/null 2>&1 && echo up || echo down",
                                                  "matrix kill")

    ssh(IRAN, "pkill -x iperf3; systemctl start frp-sink")
    ssh(GER, "pkill -x iperf3")

    res["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, "phase8-night-manual.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    with open(os.path.join(RESULTS, "phase8-night-manual.log"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines) + "\n")
    subprocess.run(["git", "add", "results/"], cwd=LAB)
    subprocess.run(["git", "commit", "-q", "-m", "phase8 night: manual engine matrix + failover (job crashed on mktime)"], cwd=LAB)
    subprocess.run(["git", "push", "-q", "origin", "HEAD:phase1/lab"], cwd=LAB)
    log("manual phases complete; results committed")


if __name__ == "__main__":
    main()
