#!/usr/bin/env python3
"""Memory of coding agents, for the Herdr app's agent-memory mod (and you).

  agent_mem.py [--slice NAME] [KEY=c:CONTAINER[@PID] | KEY=p:PID ...]

KEY=c:CONTAINER  an agent in a codebox container (ccbox, ocbox, qcbox, cxbox,
                 ompbox); @PID is its init PID when already known (skips the
                 `podman inspect`)
KEY=p:PID        an agent running directly on this machine: the process tree
                 under PID

Prints JSON: {"items": {KEY: {"bytes", "approx", "pid"}}, "slice": {...}}.
With no agents, it only reports the shared memory budget (codebox.slice), so
`agent_mem.py` alone is a quick check from a shell.

Memory is the working set: cgroup memory.current minus the inactive page cache
(files the agents touched, which the kernel drops first), as kubelet and
cAdvisor count it. Host agents get the resident memory of their processes
("approx"). Standard library only.
"""

import json
import os
import subprocess
import sys

CGROUP_ROOT = os.environ.get("CODEBOX_CGROUP_ROOT", "/sys/fs/cgroup")
PROC_ROOT = os.environ.get("CODEBOX_PROC_ROOT", "/proc")


def read_int(path):
    try:
        with open(path) as f:
            value = f.read().strip()
        return None if value == "max" else int(value)
    except (OSError, ValueError):
        return None


def working_set(cgdir):
    """(working set, reclaimable page cache) of a cgroup directory, in bytes."""
    current = read_int(f"{cgdir}/memory.current")
    if current is None:
        return None, None
    inactive_file = 0
    try:
        with open(f"{cgdir}/memory.stat") as f:
            for line in f:
                key, _, value = line.partition(" ")
                if key == "inactive_file":
                    inactive_file = int(value)
                    break
    except (OSError, ValueError):
        pass
    cache = min(inactive_file, current)
    return current - cache, cache


def container_pids(names):
    """Container name -> host PID of its init process."""
    if not names:
        return {}
    try:
        out = subprocess.run(
            ["podman", "inspect", "--format", "{{.Name}}\t{{.State.Pid}}", *names],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    pids = {}
    for line in out.splitlines():
        name, _, pid = line.partition("\t")
        if pid.isdigit() and int(pid) > 0:
            pids[name.lstrip("/")] = int(pid)
    return pids


def cgroup_of(pid):
    try:
        with open(f"{PROC_ROOT}/{pid}/cgroup") as f:
            path = next((line[3:].strip() for line in f if line.startswith("0::")), None)
    except OSError:
        return None
    if path and os.path.basename(path) == "container":  # podman's inner sub-cgroup
        path = os.path.dirname(path)
    return path


def container_memory(pid):
    path = cgroup_of(pid)
    # Only trust a cached PID that still sits in a podman scope
    if not path or "libpod-" not in path:
        return None
    return working_set(f"{CGROUP_ROOT}{path}")[0]


def process_table():
    page = os.sysconf("SC_PAGE_SIZE")
    children, rss = {}, {}
    for entry in os.listdir(PROC_ROOT):
        if not entry.isdigit():
            continue
        try:
            with open(f"{PROC_ROOT}/{entry}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue
        pid = int(entry)
        children.setdefault(int(fields[1]), []).append(pid)
        rss[pid] = int(fields[21]) * page
    return children, rss


def tree_rss(root, table):
    children, rss = table
    if root not in rss:
        return None
    total, stack = 0, [root]
    while stack:
        pid = stack.pop()
        total += rss.get(pid, 0)
        stack.extend(children.get(pid, []))
    return total


def slice_stats(name):
    uid = os.getuid()
    base = f"{CGROUP_ROOT}/user.slice/user-{uid}.slice/user@{uid}.service/{name}"
    if not os.path.isdir(base):
        return None
    used, cache = working_set(base)
    return {"current": used, "cache": cache,
            "high": read_int(f"{base}/memory.high"), "max": read_int(f"{base}/memory.max")}


def main(argv):
    slice_name = "codebox.slice"
    specs = []
    args = iter(argv)
    for arg in args:
        if arg == "--slice":
            slice_name = next(args, slice_name)
        elif arg.startswith("--slice="):
            slice_name = arg.split("=", 1)[1]
        elif "=" in arg:
            key, _, spec = arg.partition("=")
            kind, _, value = spec.partition(":")
            specs.append((key, kind, value))
        else:
            sys.exit(f"unexpected argument: {arg}")

    items = {}
    # Containers: a known PID is reused while it is still a podman scope
    lookup = []
    for key, kind, value in specs:
        if kind != "c":
            continue
        name, _, pid = value.partition("@")
        mem = container_memory(int(pid)) if pid.isdigit() else None
        if mem is None:
            lookup.append((key, name))
        else:
            items[key] = {"bytes": mem, "approx": False, "pid": int(pid)}
    found = container_pids(sorted({name for _, name in lookup}))
    for key, name in lookup:
        pid = found.get(name)
        items[key] = {"bytes": container_memory(pid) if pid else None, "approx": False, "pid": pid}

    hosts = [(key, value) for key, kind, value in specs if kind == "p" and value.isdigit()]
    if hosts:
        table = process_table()
        for key, pid in hosts:
            items[key] = {"bytes": tree_rss(int(pid), table), "approx": True, "pid": int(pid)}

    json.dump({"items": items, "slice": slice_stats(slice_name)}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
