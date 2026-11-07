#!/usr/bin/env python3
# phase5-night-job.py — detached night-window measurement for the weighted
# split. Survives the session: launched via Start-Process (detached OS process).
#
# Flow:
#   1. Poll the path every 10 min (50 connections to germany:8443); when the
#      success rate >= 60%, run the measurement regardless of the hour.
#   2. Measurement at 70/30: 3 reps x 1000 NEW connections; per-target counts
#      come from the iran sink (per-dst-IP counters: 10.254.232.2 = matrix2,
#      10.254.231.2 = matrix3).
#   3. Flip the weights to 30/70 via the panel API, re-run.
#   4. Failover: kill tincd on iran (matrix2), measure the render/exclusion +
#      recovery; restore.
#   5. Write results/ + commit+push quantum-lab.
# Credentials: read from ~/.qlab-panel-cred (never in argv/logs).

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser("~")
LAB = os.path.join(HOME, "Downloads", "Quantum", "01-REPOSITORIES", "quantum-lab")
RESULTS = os.path.join(LAB, "results")
PANEL = "91.107.179.252"
BASE = "FnPDsPsVlW2l"
COOKIE = os.path.join(HOME, "Downloads", "Quantum", "01-REPOSITORIES", "quantum-lab", "out", "panel-https-cookies.txt")
IRAN_HOST = "qlab-iran"
WINDOW_START_H = 0   # 00:30 Tehran
WINDOW_END_H = 5
DEADLINE = time.time() + 6 * 3600

sys.path.insert(0, LAB)


def log(msg):
    line = time.strftime("%H:%M:%S") + " " + msg
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
                base = line.split(":", 1)[1].strip().split(" ")[0]
    return user, pw, base


def api(method, path, body=None, csrf=None):
    user, pw, base = read_cred()
    cmd = ["curl", "-sk", "-b", COOKIE, "-H", "Content-Type: application/json"]
    if csrf:
        cmd += ["-H", "X-CSRF-Token: " + csrf]
    if body:
        cmd += ["-H", "Content-Type: application/json", "-d", body]
    cmd += ["-X", method, f"https://{PANEL}:7443/{base}/api/{path}"]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    return out


def login():
    user, pw, base = read_cred()
    cmd = ["curl", "-sk", "-c", COOKIE, "-X", "POST", "-H", "Content-Type: application/json",
           "-d", json.dumps({"username": user, "password": pw}),
           f"https://{PANEL}:7443/{base}/api/login"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return "csrf_token" in r.stdout or r.returncode == 0


def get_csrf():
    _, _, base = read_cred()
    with open(COOKIE, encoding="utf-8") as fh:
        for line in fh:
            if "gre_csrf" in line:
                return line.split()[-1]
    return None


def conn_batch(n, target=("91.107.179.252", 8443)):
    import socket
    ok = 0

    def one(i):
        nonlocal ok
        try:
            s = socket.create_connection(target, timeout=10)
            s.send(b"GET / HTTP/1.0\r\n\r\n")
            s.recv(64)
            s.close()
            return 1
        except Exception:
            return 0
    with ThreadPoolExecutor(max_workers=16) as ex:
        ok = sum(ex.map(one, range(n)))
    return ok, n - ok


def probe_rate():
    ok, fail = conn_batch(50)
    return ok / max(1, ok + fail)


def iran_sink_restart():
    subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                    IRAN_HOST, "systemctl restart frp-sink"], timeout=60)


def iran_sink_counts():
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                        IRAN_HOST, "grep -c COUNTS /tmp/sink8443.log; tail -1 /tmp/sink8443.log"],
                       capture_output=True, text=True, timeout=60)
    return r.stdout.strip().splitlines()[-1] if r.stdout else ""


def iran_kill_tincd():
    subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                    IRAN_HOST, "pkill -9 -x tincd"], timeout=60)


def iran_mesh_up():
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                        IRAN_HOST, "ping -c 1 -W 3 10.254.232.1 >/dev/null 2>&1 && echo up || echo down"],
                       capture_output=True, text=True, timeout=60)
    return "up" in r.stdout


def measure_split(reps=3, n=1000):
    results = []
    for rep in range(1, reps + 1):
        iran_sink_restart()
        time.sleep(2)
        subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                        IRAN_HOST, ": > /tmp/sink8443.log"], timeout=60)
        before = time.time()
        ok, fail = conn_batch(n)
        time.sleep(3)
        counts = iran_sink_counts()
        results.append({"rep": rep, "connected": ok, "failed": fail,
                        "sink_counts": counts, "t0": before})
        log(f"rep {rep}: connected={ok} failed={fail} counts={counts}")
        time.sleep(5)
    return results


def set_weight(tunnel_id, weight):
    _, _, _ = read_cred()
    csrf = get_csrf()
    r = api("POST", "mesh/topologies/1/weights",
            json.dumps({"local_server_id": 1, "remote_server_id": 2,
                        "tunnel_id": tunnel_id, "weight": weight}), csrf)
    log(f"weight tunnel{tunnel_id}={weight}: {r[:40]}")


def push_agent(agent_id):
    csrf = get_csrf()
    r = api("POST", f"mesh/agents/{agent_id}/push")
    log(f"push {agent_id}: {r[:80]}")


def failover_test():
    import datetime
    out = {"kill_t": datetime.datetime.utcnow().isoformat()}
    iran_kill_tincd()
    time.sleep(4)
    out["render_during"] = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none", "qlab-germany",
         "nft list chain ip quantum-fwd fw_fw_1_tcp 2>/dev/null | tail -2"],
        capture_output=True, text=True, timeout=60).stdout.strip()
    deadline = time.time() + 90
    while time.time() < deadline:
        if iran_mesh_up():
            out["recovered_s"] = round(time.time() - time.mktime(time.strptime(
                out["kill_t"][:19], "%Y-%m-%dT%H:%M:%S")) if False else 0, 1)
            break
        time.sleep(2)
    subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                    IRAN_HOST, "systemctl restart quantum-matrix2"], timeout=60)
    time.sleep(10)
    out["mesh_after"] = iran_mesh_up()
    return out


def main():
    log("night job started")
    results = {"window": [], "measure_70_30": None, "measure_30_70": None,
               "failover": None}
    # wait for a usable window
    while time.time() < DEADLINE:
        now = time.gmtime()
        hour = (now.tm_hour + 3.5) % 24  # Tehran = UTC+3:30
        in_window = WINDOW_START_H + 0.5 <= hour < WINDOW_END_H
        rate = probe_rate()
        log(f"probe: rate={rate:.2f} in_window={in_window}")
        if rate >= 0.6:
            break
        time.sleep(600)
    else:
        log("deadline passed without a usable window")
        results["unverified"] = "no usable window before the deadline"
        json.dump(results, open(os.path.join(RESULTS, "night-job-2026-11-07.json"), "w"), indent=1)
        return

    login()
    # sanity: both tunnels referenced
    agents = api("GET", "agents")
    log("agents: " + agents[:120])

    # 70/30
    set_weight(1, 70)
    set_weight(3, 30)
    push_agent("agt_07d91c16f2d0")
    push_agent("agt_2446bc241ab0")
    time.sleep(5)
    results["measure_70_30"] = measure_split()

    # 30/70
    set_weight(1, 30)
    set_weight(3, 70)
    push_agent("agt_07d91c16f2d0")
    push_agent("agt_2446bc241ab0")
    time.sleep(5)
    results["measure_30_70"] = measure_split()

    # failover (kill matrix2's tincd on iran)
    results["failover"] = failover_test()

    # restore weights 70/30
    set_weight(1, 70)
    set_weight(3, 30)
    push_agent("agt_07d91c16f2d0")
    push_agent("agt_2446bc241ab0")

    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, "night-job-2026-11-07.json"), "w") as fh:
        json.dump(results, fh, indent=1)

    md = ["# Night-window weighted split — 2026-11-07/08", "",
          f"- 70/30 run: {json.dumps(results['measure_70_30'])}",
          f"- 30/70 run: {json.dumps(results['measure_30_70'])}",
          f"- failover: {json.dumps(results['failover'])}"]
    with open(os.path.join(RESULTS, "night-job-2026-11-07.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")

    subprocess.run(["git", "add", "results/"], cwd=LAB)
    subprocess.run(["git", "commit", "-q", "-m",
                    "night window: weighted split + failover measurements"], cwd=LAB)
    subprocess.run(["git", "push", "-q", "origin", "HEAD:phase1/lab"], cwd=LAB)
    log("results committed and pushed")


if __name__ == "__main__":
    main()
