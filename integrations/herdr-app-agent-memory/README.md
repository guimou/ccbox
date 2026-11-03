# Herdr app mod: agent memory

A panel for the [Herdr app](https://herdr.dev) that shows how much memory each agent uses, and the [shared memory budget](../../docs/usage.md#memory-budget) all agents run in.

- **Per agent**: every agent in a ccbox / ocbox / qcbox / cxbox / ompbox container shows its container's memory, largest first, with a bar relative to the largest. Agents running directly on this computer show the resident memory of their processes, marked `~` (approximate). Agents on another machine show `remote`. Click a row to go to that agent.
- **Budget**: the total for all agents against the budget's throttling threshold (`MemoryHigh`), with a bar that turns yellow at 60% and red at 85%, plus the hard limit and how much of the slice is reclaimable cache.
- **Alert**: a toast once when the agents reach 85% of the threshold, naming the largest agent (click it to go there). It re-arms when usage drops back.

Memory is the *working set*: the cgroup's memory minus the inactive page cache (files the agents read or wrote, which the kernel drops first under pressure), as kubelet and cAdvisor count it. `systemctl --user status codebox.slice` shows the raw figure, cache included, so it reads higher.

Requires Linux, `python3` (standard library only) and the launchers' shared memory budget (without it, the per-agent numbers still work and the header says the budget is not active).

## Install

The folder must be named `agent-memory` under the app's mods. From a clone of this repository:

```bash
ln -s /path/to/ccbox/integrations/herdr-app-agent-memory ~/.config/herdr-app/mods/agent-memory
herdr-app check ~/.config/herdr-app/mods/agent-memory
```

(Or copy the folder instead of linking it.) The first time the app sees the folder it docks the panel on the right of the shown layout; after that, the layout decides, so move or resize it like any other block (or ask your agent to put it somewhere else).

## Tuning

At the top of `main.js`:

```js
const INTERVAL_MS = 5000;   // how often to sample
const ALERT_PERCENT = 85;   // toast at this share of the budget's MemoryHigh
const SLICE = "codebox.slice";  // match CODEBOX_SLICE if you changed it
```

Saving reloads the panel.

## How it works

Every 5 seconds the panel takes the app's `agents()` and `terminals()`. Each terminal's foreground process tells it where the agent runs: a `podman run --name <box>-…` is a codebox container; anything else is a program on this computer. It then calls `agent_mem.py` next to it, which:

1. gets each container's init PID with `podman inspect` (once: the panel passes the PID back on later samples, and it is re-checked every time), reads that container's cgroup, and subtracts `inactive_file` from `memory.current`;
2. sums the resident memory of a host agent's process tree from `/proc`;
3. reads `codebox.slice`'s totals and limits.

The helper also works from a shell:

```bash
python3 agent_mem.py                       # the budget only
python3 agent_mem.py a=c:ccbox-myrepo-…    # one container, by name
```
