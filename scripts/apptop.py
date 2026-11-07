#!/usr/bin/env python3
"""apptop: total CPU and RAM per app, including every child process it spawned.

Activity Monitor shows each process on its own row, so an app that starts
scripts and terminals looks idle while its children do the work. This script
walks each process up to the .app that started it and adds the numbers together.

Usage:  python3 scripts/apptop.py            # refresh every 2 s
        python3 scripts/apptop.py --once     # print once and exit
        python3 scripts/apptop.py --detail Claude   # list the busiest children of one app
"""
import os
import re
import subprocess
import sys
import time
from collections import defaultdict

APP_RE = re.compile(r"/([^/]+)\.app/")


def snapshot():
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pcpu=,rss=,comm="],
        capture_output=True, text=True, check=True,
    ).stdout
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, ppid, cpu, rss, comm = parts
        procs[int(pid)] = (int(ppid), float(cpu), int(rss), comm)
    return procs


def owner(pid, procs, cache):
    """Return the outermost .app this process lives under, or a fallback name."""
    if pid in cache:
        return cache[pid]
    chain, app, cur = [], None, pid
    while cur in procs and cur not in (0, 1):
        chain.append(cur)
        if cur in cache:
            app = cache[cur]
            break
        m = APP_RE.search(procs[cur][3])
        if m:
            app = m.group(1)  # keep climbing: the outermost .app wins
        cur = procs[cur][0]
    if app is None:
        app = os.path.basename(procs[pid][3]) if pid in procs else "?"
    for p in chain:
        cache.setdefault(p, app)
    return app


def totals(procs):
    cache = {}
    agg = defaultdict(lambda: [0.0, 0, 0])  # cpu, rss_kb, count
    for pid, (_, cpu, rss, _) in procs.items():
        a = agg[owner(pid, procs, cache)]
        a[0] += cpu
        a[1] += rss
        a[2] += 1
    return agg, cache


def show(limit=20):
    procs = snapshot()
    agg, _ = totals(procs)
    rows = sorted(agg.items(), key=lambda kv: kv[1][0], reverse=True)[:limit]
    ncpu = os.cpu_count() or 1
    print(f"{'APP (incl. children)':32} {'CPU %':>7} {'RAM':>9} {'PROCS':>6}")
    print(f"{'':32} {'(100% = 1 core, max ' + str(ncpu * 100) + '%)'}")
    for name, (cpu, rss, n) in rows:
        print(f"{name[:32]:32} {cpu:7.1f} {rss / 1048576:7.2f} GB {n:6}")


def detail(app, limit=25):
    procs = snapshot()
    _, cache = totals(procs)
    mine = [(pid, *procs[pid]) for pid in procs if cache.get(pid, "").lower() == app.lower()]
    mine.sort(key=lambda r: r[2], reverse=True)
    print(f"{'PID':>7} {'CPU %':>7} {'RAM MB':>8}  COMMAND   (all processes under {app})")
    for pid, _, cpu, rss, comm in mine[:limit]:
        print(f"{pid:7} {cpu:7.1f} {rss / 1024:8.0f}  {comm[-90:]}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--detail"] and len(args) > 1:
        detail(" ".join(args[1:]))
    elif args[:1] == ["--once"]:
        show()
    else:
        try:
            while True:
                os.system("clear")
                show()
                time.sleep(2)
        except KeyboardInterrupt:
            pass
