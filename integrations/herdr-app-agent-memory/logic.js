// Pure helpers for the agent-memory mod (no Herdr or GPUI imports, so they
// can be tested outside the app).

// The codebox container a terminal's foreground process runs, if any:
// ccbox / ocbox / qcbox / cxbox / ompbox exec `podman run ... --name <box>-...`.
export function containerName(argv) {
  if (!Array.isArray(argv) || argv.length === 0) return null;
  if (!/(^|\/)podman$/.test(argv[0]) || !argv.includes("run")) return null;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === "--name" && i + 1 < argv.length) return argv[i + 1];
    if (argv[i].startsWith("--name=")) return argv[i].slice(7);
  }
  return null;
}

// The ccbox / ocbox / qcbox / cxbox / ompbox launcher itself (directly, or
// as `bash ccbox ...` when started through a shell script).
export function isLauncher(argv) {
  if (!Array.isArray(argv)) return false;
  const base = (s) => (s ?? "").split("/").pop();
  return /^(cc|oc|qc|cx|omp)box$/.test(base(argv[0])) ||
    (/^(ba|z)?sh$/.test(base(argv[0])) && /^(cc|oc|qc|cx|omp)box$/.test(base(argv[1])));
}

// What to measure for each local agent: its container (with the PID learned
// last time, so the helper can skip `podman inspect`), else its process tree.
// Agents on another machine are left out (shown as "remote").
export function targets(agentList, terminalList, spaceList, knownPids) {
  const byAddress = new Map(terminalList.map((t) => [t.address, t]));
  const machineOf = new Map(spaceList.map((s) => [s.id, s.machine]));
  const out = [];
  for (const a of agentList) {
    if (machineOf.get(a.space)) {
      out.push({ address: a.address, remote: true });
      continue;
    }
    const term = byAddress.get(a.address);
    const fg = term?.foreground;
    const name = containerName(fg?.argv);
    if (!name && (isLauncher(fg?.argv) || (!fg && isLauncher(term?.argv)))) {
      // A box launcher not yet exec'd into podman (pulling, starting): its
      // own processes are not the agent, so show nothing rather than a wrong number
      out.push({ address: a.address });
    } else if (name) {
      const pid = knownPids[name];
      out.push({ address: a.address, kind: "c", container: name, arg: `${a.address}=c:${name}${pid ? `@${pid}` : ""}` });
    } else if (fg?.pid || term?.pid) {
      out.push({ address: a.address, kind: "p", arg: `${a.address}=p:${fg?.pid ?? term.pid}` });
    } else {
      out.push({ address: a.address });
    }
  }
  return out;
}

export function fmt(bytes) {
  if (bytes == null) return "–";
  const gib = bytes / 1024 ** 3;
  if (gib >= 100) return `${gib.toFixed(0)}G`;
  if (gib >= 1) return `${gib.toFixed(1)}G`;
  return `${(bytes / 1024 ** 2).toFixed(0)}M`;
}

// Share of the throttling threshold (else the hard limit) used, or null.
export function budgetPercent(slice) {
  if (!slice || slice.current == null) return null;
  const limit = slice.high ?? slice.max;
  return limit ? (slice.current * 100) / limit : null;
}

// Alert once per crossing; re-arm when usage drops 5 points below.
export function nextAlert(pct, alerted, threshold) {
  if (pct == null) return { alerted, fire: false };
  if (pct < threshold - 5) return { alerted: false, fire: false };
  if (!alerted && pct >= threshold) return { alerted: true, fire: true };
  return { alerted, fire: false };
}
