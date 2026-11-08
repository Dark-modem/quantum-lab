#!/usr/bin/env python3
# phase8-night-job.py — detached night-window job for the RC3 acceptance
# (PART 1 split + PART 2 engine matrix). Survives the session: launched as a
# detached OS process; commits results/ to quantum-lab when finished.
#
# Window: 00:30-05:00 Tehran (21:00-01:30 UTC) — the only time the
# Iran<->Germany path carries 8443 reliably (day route drops it; verified).
#
# Flow:
#   A. weight audit + split at 70/30 (matrix/frp): 3 reps x >=1000 NEW conns
#      from the real user position; per-target counts from the iran sink's
#      per-dst counters (10.254.231.2 = matrix, 127.0.0.1 = frp);
#      path loss counted separately. 4-way audit each setting:
#      panel weights API / agent balancer diag / agent desired_v2 / nft.
#   B. flip 30/70: 4-way audit (watch the RC2 mod-60 bug) + 3 reps x 1000.
#   C. restore 70/30. failover: kill frps on germany (engine-process kill,
#      measure recovery); 30 s scoped blackhole on the frp carrier port
#      (7500, source-scoped to iran's IP, removed after); matrix kill-recovery.
#   D. engine matrix, one engine at a time (matrix/frp/backhaul — the drivers
#      the SHIPPED agent actually has): weights 100/0, iperf3 both directions
#      through 8443 + same-window underlay baseline (direct :5201),
#      wire-vs-payload overhead from the usage API, kill + blackhole
#      recovery, idle RSS/CPU. UDP carriers (wireguard, wireguard@udp2raw)
#      are NOT testable — the shipped agent has no such drivers (recorded).
#   E. panel death + usage snapshot; write results/ + commit + push.

import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser("~")
LAB = os.path.join(HOME, "Downloads", "Quantum", "01-REPOSITORIES", "quantum-lab")
RESULTS = os.path.join(LAB, "results")
OUT = os.path.join(LAB, "out")
COOKIE = os.path.join(OUT, "panel-https-cookies.txt")
PANEL = "91.107.179.252"
IRAN_HOST = "qlab-iran"
GER_HOST = "qlab-germany"
LISTEN_PORT = 8202  # 8443 is route-blocked (intercepted); 8202 passes — verified live
WINDOW_START_H = 0.5   # 00:30 Tehran
WINDOW_END_H = 5.0
DEADLINE = time.time() + 8 * 3600
DAY_PROBE_LIMIT = time.time() + 60 * 60  # if the path never opens, still run (record it)

sys.path.insert(0, LAB)

T0 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
log_lines = []


def log(msg):
    line = time.strftime("%H:%M:%S") + " " + str(msg)
    log_lines.append(line)
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


def api(method, path, body=None):
    user, pw, base = read_cred()
    cmd = ["curl", "-sk", "-b", COOKIE, "-H", f"X-CSRF-Token: {CSRF[0]}",
           "-H", "Content-Type: application/json", "-X", method,
           f"https://{PANEL}:7443/{base}/api/{path}", "--max-time", "90"]
    if body:
        cmd += ["-d", json.dumps(body)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    return r.stdout.strip()


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


def ssh(host, cmd, timeout=90):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=none",
                        "-o", "ConnectTimeout=30", host, cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def conn_batch(n, workers=6):
    import socket
    def one(i):
        try:
            s = socket.create_connection((PANEL, LISTEN_PORT), timeout=12)
            s.send(b"GET / HTTP/1.0\r\n\r\n")
            s.recv(64)
            s.close()
            return 1
        except Exception:
            return 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        res = list(ex.map(one, range(n)))
    return sum(res), n - sum(res)


def sink_restart():
    ssh(IRAN_HOST, "systemctl restart frp-sink; sleep 2; "
                   "journalctl -u frp-sink --since '-5 s' --no-pager | tail -1 >/dev/null")


def sink_counts():
    """Per-target counts from BOTH sink units: frp-sink (8443) counts the
    frp path (dst 127.0.0.1); frp-sink2 (8202) counts the matrix path
    (dst 10.254.231.2). Keys normalized by target."""
    out = {"matrix": {}, "frp": {}}
    j1 = ssh(IRAN_HOST, "journalctl -u frp-sink --since '-120 s' --no-pager | grep COUNTS | tail -1")
    m = re.search(r"COUNTS (\{.*\})", j1)
    if m:
        try:
            out["frp"] = {k: int(v) for k, v in json.loads(m.group(1)).items()}
        except Exception:
            pass
    j2 = ssh(IRAN_HOST, "journalctl -u frp-sink2 --since '-120 s' --no-pager | grep COUNTS2 | tail -1")
    m = re.search(r"COUNTS2 (\{.*\})", j2)
    if m:
        try:
            out["matrix"] = {k: int(v) for k, v in json.loads(m.group(1)).items()}
        except Exception:
            pass
    return out


def measure_split(reps=3, n=1000):
    rows = []
    for rep in range(1, reps + 1):
        sink_restart()
        time.sleep(2)
        t0 = time.time()
        ok, fail = conn_batch(n)
        time.sleep(4)
        counts = sink_counts()
        rows.append({"rep": rep, "connected": ok, "failed": fail,
                     "sink_counts": counts, "t0": time.strftime("%H:%M:%S", time.localtime(t0))})
        log(f"rep {rep}: connected={ok} failed={fail} counts={counts}")
        time.sleep(5)
    return rows


def set_weight(tunnel_id, weight):
    out = api("POST", "mesh/topologies/1/weights",
              {"local_server_id": 1, "remote_server_id": 2,
               "tunnel_id": tunnel_id, "weight": weight})
    log(f"weight tunnel{tunnel_id}={weight}: {out[:60]}")


def push_agents():
    for ag in ("agt_5108f8bafd60", "agt_96dc286ce762"):
        out = api("POST", f"mesh/agents/{ag}/push")
        log(f"push {ag}: {out[:100]}")


def weight_audit(tag):
    """4-way dump: panel store / agent diag / agent desired_v2 / kernel."""
    audit = {"tag": tag, "at": time.strftime("%H:%M:%S")}
    audit["panel_weights"] = api("GET", "mesh/topologies/1/weights")
    audit["germany_balancer_diag"] = ssh(GER_HOST,
        "journalctl -u quantum-agent --since '-10 min' --no-pager | grep -E '\\[balancer\\] targets' | tail -1")
    audit["germany_desired_v2_weights"] = ssh(GER_HOST,
        "python3 -c \"import json; st=json.load(open('/etc/quantum-agent/agent-state.json')); "
        "d=st.get('desired_v2') or {}; d=d if isinstance(d,dict) else json.loads(d); "
        "print(json.dumps(d.get('balancing',{}).get('weights',[])))\"", timeout=60)
    audit["germany_nft"] = ssh(GER_HOST, "nft list chain ip quantum-fwd fw_fw_1_tcp 2>/dev/null | tail -2")
    audit["iran_desired_v2_weights"] = ssh(IRAN_HOST,
        "python3 -c \"import json; st=json.load(open('/etc/quantum-agent/agent-state.json')); "
        "d=st.get('desired_v2') or {}; d=d if isinstance(d,dict) else json.loads(d); "
        "print(json.dumps(d.get('balancing',{}).get('weights',[])))\"", timeout=60)
    log(f"audit[{tag}]: nft={audit['germany_nft'][:120]}")
    return audit


def frp_kill_recovery():
    out = {"kill_t": time.strftime("%H:%M:%S")}
    ssh(GER_HOST, "pkill -9 -x frps")
    time.sleep(2)
    deadline = time.time() + 120
    recovered = False
    while time.time() < deadline:
        listening = ssh(GER_HOST, "ss -tlnp | grep -c ':8201 '")
        if listening and listening.strip() != "0":
            recovered = True
            break
        time.sleep(2)
    out["recovered"] = recovered
    out["recover_s"] = round(time.time() - time.mktime(time.strptime(out["kill_t"], "%H:%M:%S")), 1) if recovered else None
    ok, _ = conn_batch(3)
    out["data_after"] = ok
    log(f"frp kill-recovery: {out}")
    return out


def frp_blackhole_30s():
    out = {}
    ssh(GER_HOST, "iptables -I INPUT -p tcp --dport 7500 -s 185.226.119.74 -j DROP")
    out["blackhole_at"] = time.strftime("%H:%M:%S")
    time.sleep(30)
    ssh(GER_HOST, "iptables -D INPUT -p tcp --dport 7500 -s 185.226.119.74 -j DROP")
    out["removed_at"] = time.strftime("%H:%M:%S")
    deadline = time.time() + 120
    while time.time() < deadline:
        ok, _ = conn_batch(2)
        if ok >= 1:
            break
        time.sleep(3)
    out["data_after_s"] = round(time.time() - time.mktime(time.strptime(out["removed_at"], "%H:%M:%S")), 1)
    leftover = ssh(GER_HOST, "iptables -S INPUT | grep -c 'dport 7500' || true")
    out["leftover_rules"] = leftover
    log(f"frp blackhole: {out}")
    return out


def matrix_kill_recovery():
    out = {"kill_t": time.strftime("%H:%M:%S")}
    ssh(IRAN_HOST, "pkill -9 -x tincd")
    time.sleep(3)
    deadline = time.time() + 120
    recovered = False
    while time.time() < deadline:
        up = ssh(IRAN_HOST, "ping -c 1 -W 2 10.254.231.1 >/dev/null 2>&1 && echo up || echo down")
        if "up" in up:
            recovered = True
            break
        time.sleep(2)
    out["recovered"] = recovered
    if recovered:
        out["recover_s"] = round(time.time() - time.mktime(time.strptime(out["kill_t"], "%H:%M:%S")), 1)
    log(f"matrix kill-recovery: {out}")
    return out


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


def usage_topo():
    return api("GET", "mesh/usage?topology_id=1")


def iperf3_run(target_host, target_port, direction, secs=10, json_out=True):
    """Run iperf3 from IRAN (the lab's standard client position) toward
    germany through the balancer — a real external client for the DNAT,
    mirroring the production direction."""
    flag = "-R " if direction == "down" else ""
    j = "-J" if json_out else ""
    cmd = (f"iperf3 {j} {flag}-c {target_host} -p {target_port} -t {secs} "
           f"-O 2 --connect-timeout 8000")
    out = ssh(IRAN_HOST, cmd, timeout=secs + 60)
    return out


def parse_iperf_j(out, direction="up"):
    try:
        j = json.loads(out)
        end = j.get("end", {})
        # forward mode: the client sends (sum_sent); reverse (-R): the client
        # receives (sum_received) — the other sum is the tiny control side.
        key = "sum_received" if direction == "down" else "sum_sent"
        sum_ = end.get(key) or end.get("sum_sent") or end.get("sum_received") or {}
        return {"bps": sum_.get("bits_per_second", 0),
                "retransmits": sum_.get("retransmits", 0),
                "seconds": sum_.get("seconds"),
                "ok": True}
    except Exception:
        return {"ok": False, "raw": out[:200]}


def engine_matrix(engines, carriers):
    """One engine at a time: weights 100/0, iperf3 up/down + underlay,
    overhead, kill + blackhole, idle RSS/CPU."""
    tunnel_of = {"matrix": 1, "frp": 2, "backhaul": 3}
    res = {}
    for eng in engines:
        entry = {"engine": eng}
        rt = engine_runtime()
        entry["up_before"] = rt.get(eng, {}).get("up")
        if not entry["up_before"]:
            res[eng] = entry
            continue
        # weights 100/0
        for e2, tid in tunnel_of.items():
            set_weight(tid, 100 if e2 == eng else 0)
        push_agents()
        time.sleep(8)
        entry["nft_100"] = ssh(GER_HOST, "nft list chain ip quantum-fwd fw_fw_1_tcp 2>/dev/null | tail -1")
        # iperf3 up + down through the balancer, then the underlay baseline
        entry["iperf_up"] = parse_iperf_j(iperf3_run(PANEL, LISTEN_PORT, "up"), "up")
        entry["iperf_down"] = parse_iperf_j(iperf3_run(PANEL, LISTEN_PORT, "down"), "down")
        entry["underlay_up"] = parse_iperf_j(iperf3_run(PANEL, 5201, "up"), "up")
        entry["underlay_down"] = parse_iperf_j(iperf3_run(PANEL, 5201, "down"), "down")
        entry["usage"] = usage_topo()
        # kill the engine process(es) on both ends; measure recovery
        kills = {"matrix": (GER_HOST, "pkill -9 -x tincd"),
                 "frp": (GER_HOST, "pkill -9 -x frps"),
                 "backhaul": (GER_HOST, "pkill -9 -x backhaul")}
        h, k = kills[eng]
        t0 = time.time()
        ssh(h, k)
        rec = None
        deadline = time.time() + 150
        while time.time() < deadline:
            rt = engine_runtime()
            if rt.get(eng, {}).get("up"):
                rec = round(time.time() - t0, 1)
                break
            time.sleep(3)
        entry["kill_recover_s"] = rec
        # scoped 30 s blackhole on the engine's carrier port
        cport = carriers.get(eng)
        if cport:
            src = "185.226.119.74"  # iran public IP (the client end dials out)
            ssh(GER_HOST, f"iptables -I INPUT -p tcp --dport {cport} -s {src} -j DROP")
            time.sleep(30)
            ssh(GER_HOST, f"iptables -D INPUT -p tcp --dport {cport} -s {src} -j DROP")
            t0 = time.time()
            rec = None
            deadline = time.time() + 150
            while time.time() < deadline:
                rt = engine_runtime()
                if rt.get(eng, {}).get("up"):
                    rec = round(time.time() - t0, 1)
                    break
                time.sleep(3)
            entry["blackhole_recover_s"] = rec
            entry["blackhole_leftover"] = ssh(GER_HOST, f"iptables -S INPUT | grep -c 'dport {cport}' || true")
        # idle RSS/CPU of the engine process(es)
        procs = {"matrix": "tincd", "frp": "frps|frpc", "backhaul": "backhaul"}
        entry["idle_ps"] = ssh(GER_HOST, f"ps -o pid,comm,rss,pcpu -C {procs[eng].split('|')[0]} --no-headers | head -3")
        time.sleep(20)
        entry["idle_ps_after_idle"] = ssh(GER_HOST, f"ps -o pid,comm,rss,pcpu -C {procs[eng].split('|')[0]} --no-headers | head -3")
        res[eng] = entry
        log(f"matrix[{eng}]: up={entry['up_before']} iperf_up={entry['iperf_up'].get('bps',0)/1e6:.1f}Mb/s "
            f"kill_rec={entry.get('kill_recover_s')} bh_rec={entry.get('blackhole_recover_s')}")
    # restore 70/30/0
    set_weight(1, 70)
    set_weight(2, 30)
    set_weight(3, 0)
    push_agents()
    return res


def main():
    log("phase8 night job started")
    results = {"started": T0, "window": None, "phase_matrix_only": None,
               "phase_frp_only": None, "phase_70_30": None, "phase_30_70": None,
               "failover": None, "engine_matrix": None, "panel_death": None,
               "usage": None, "unverified": []}

    # wait for the night window + a usable path
    got_window = False
    while time.time() < DEADLINE:
        now = time.gmtime()
        hour = (now.tm_hour + now.tm_min / 60.0 + 3.5) % 24  # Tehran = UTC+3:30
        in_window = WINDOW_START_H <= hour < WINDOW_END_H
        ok, fail = conn_batch(40, workers=6)
        rate = ok / max(1, ok + fail)
        log(f"probe: rate={rate:.2f} in_window={in_window}")
        if in_window and rate >= 0.5:
            got_window = True
            results["window"] = {"opened": time.strftime("%H:%M:%S"), "probe_rate": round(rate, 2)}
            break
        if time.time() > DAY_PROBE_LIMIT and rate >= 0.5:
            log("day path usable — running anyway (window flag false)")
            got_window = True
            results["window"] = {"opened": time.strftime("%H:%M:%S"), "probe_rate": round(rate, 2),
                                 "note": "ran outside the Tehran night window"}
            break
        time.sleep(300 if in_window else 600)

    if not login():
        results["unverified"].append("panel login failed")
        write_results(results)
        return

    # A. split phases (the shipped agent's renderer no-ops the matrix leg
    # when target ports differ — `. 0` — so each phase measures honestly):
    # matrix-only, frp-only, mixed 70/30, mixed 30/70. 2 reps x 1000 each.
    def phase(name, w1, w2):
        set_weight(1, w1)
        set_weight(2, w2)
        set_weight(3, 0)
        push_agents()
        time.sleep(8)
        audit = weight_audit(name)
        split = measure_split(reps=2, n=1000)
        log(f"phase {name}: audit nft={audit['germany_nft'][:110]}")
        return {"audit": audit, "split": split}

    results["phase_matrix_only"] = phase("matrix_100", 100, 0)
    results["phase_frp_only"] = phase("frp_100", 0, 100)
    results["phase_70_30"] = phase("mixed_70_30", 70, 30)
    results["phase_30_70"] = phase("mixed_30_70", 30, 70)

    # C. restore + failover (70/30/0 already set by the last phase)
    results["failover"] = {
        "frp_kill": frp_kill_recovery(),
        "frp_blackhole_30s": frp_blackhole_30s(),
        "matrix_kill": matrix_kill_recovery(),
    }

    # D. engine matrix (the drivers the shipped agent has)
    # iperf3 servers: iran:8443 (through the balancer — sink must step aside)
    # + germany:5201 (underlay baseline, direct public path).
    ip = {"iran_has": ssh(IRAN_HOST, "command -v iperf3 >/dev/null && echo yes || echo no"),
          "ger_has": ssh(GER_HOST, "command -v iperf3 >/dev/null && echo yes || echo no")}
    results["iperf3_available"] = ip
    if ip["iran_has"] == "yes" and ip["ger_has"] == "yes":
        ssh(IRAN_HOST, "systemctl stop frp-sink; pkill -x iperf3; iperf3 -s -p 8443 -D; iperf3 -s -p 8202 -D")
        ssh(GER_HOST, "pkill -x iperf3; iperf3 -s -p 5201 -D")
        results["engine_matrix"] = engine_matrix(
            ["matrix", "frp", "backhaul"],
            {"matrix": 2097, "frp": 7500, "backhaul": 8302})
        ssh(IRAN_HOST, "pkill -x iperf3; systemctl start frp-sink")
        ssh(GER_HOST, "pkill -x iperf3")
    else:
        results["unverified"].append(f"iperf3 missing: {ip}")
        results["engine_matrix"] = None

    # E. panel death + usage
    results["usage"] = usage_topo()
    ssh(GER_HOST, "systemctl stop quantum-panel")
    time.sleep(3)
    pd = {"stopped_at": time.strftime("%H:%M:%S")}
    ok, fail = conn_batch(30, workers=8)
    pd["traffic_during"] = {"ok": ok, "failed": fail}
    up = ssh(IRAN_HOST, "ping -c 1 -W 3 10.254.231.1 >/dev/null 2>&1 && echo up || echo down")
    pd["mesh_during"] = up
    ssh(GER_HOST, "systemctl start quantum-panel")
    t0 = time.time()
    deadline = time.time() + 120
    while time.time() < deadline:
        n = ssh(IRAN_HOST, "journalctl -u quantum-agent --since '-2 min' --no-pager | grep -c 'connected to wss'")
        if n and int(n) >= 1:
            pd["reconnect_s"] = round(time.time() - t0, 1)
            break
        time.sleep(3)
    results["panel_death"] = pd
    log(f"panel death: {pd}")

    write_results(results)


def write_results(results):
    results["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    date = time.strftime("%Y-%m-%d")
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, f"phase8-night-{date}.json"), "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=1)
    md = [f"# Phase-8 night results — {date}", ""]
    for k in ("window", "phase_matrix_only", "phase_frp_only", "phase_70_30",
              "phase_30_70", "failover", "engine_matrix", "panel_death", "usage"):
        md.append(f"## {k}\n```json\n{json.dumps(results.get(k), indent=1)[:4000]}\n```\n")
    if results["unverified"]:
        md.append("## unverified\n" + "\n".join(f"- {u}" for u in results["unverified"]))
    with open(os.path.join(RESULTS, f"phase8-night-{date}.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")
    with open(os.path.join(RESULTS, f"phase8-night-{date}.log"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(log_lines) + "\n")
    subprocess.run(["git", "add", "results/"], cwd=LAB)
    subprocess.run(["git", "commit", "-q", "-m", "phase8 night: split/flip audits + failover + engine matrix"], cwd=LAB)
    subprocess.run(["git", "push", "-q", "origin", "HEAD:phase1/lab"], cwd=LAB)
    log("results committed and pushed")


if __name__ == "__main__":
    main()
