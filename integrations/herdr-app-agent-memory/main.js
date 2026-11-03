// Agent memory: each agent's memory and the shared budget (codebox.slice).
// Agents in a ccbox / ocbox / qcbox / cxbox / ompbox container show their
// container's working set; agents run directly on this machine show the
// resident memory of their processes ("~", approximate). A toast warns once
// when all agents together reach ALERT_PERCENT of the budget's throttling
// threshold. The numbers come from agent_mem.py next to this file.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, spaces, theme, run, exec, appHome, notify } from "herdr";
import { targets, fmt, budgetPercent, nextAlert } from "./logic.js";

const INTERVAL_MS = 5000;
const ALERT_PERCENT = 85;
const SLICE = "codebox.slice";

export default class AgentMemory extends View {
  init(_props, cx) {
    this.mem = {};        // address -> { bytes, approx }
    this.pids = {};       // container name -> init PID (saves a podman call)
    this.slice = null;
    this.error = null;
    this.busy = false;
    this.alerted = false;
    this.width = 260;
    cx.timer.every(INTERVAL_MS, (cx) => this.refresh(cx));
    this.refresh(cx);
  }

  refresh(cx) {
    if (this.busy) return;  // a slow sample must not pile up
    this.busy = true;
    cx.spawn(async (cx) => {
      try {
        const list = targets(agents(), terminals(), spaces(), this.pids);
        const args = ["--slice", SLICE, ...list.filter((t) => t.arg).map((t) => t.arg)];
        const r = await exec("python3", [`${appHome()}/mods/agent-memory/agent_mem.py`, ...args]);
        if (r.code !== 0) throw new Error(r.stderr.trim() || `agent_mem.py exited ${r.code}`);
        const out = JSON.parse(r.stdout);
        this.mem = {};
        for (const t of list) {
          if (t.remote) this.mem[t.address] = { remote: true };
          const item = out.items[t.address];
          if (!item) continue;
          this.mem[t.address] = item;
          if (t.container && item.pid) this.pids[t.container] = item.pid;
        }
        this.slice = out.slice;
        this.error = null;
        this.alert();
      } catch (e) {
        this.error = String(e?.message ?? e);
      } finally {
        this.busy = false;
        cx.notify();
      }
    });
  }

  alert() {
    const pct = budgetPercent(this.slice);
    const next = nextAlert(pct, this.alerted, ALERT_PERCENT);
    this.alerted = next.alerted;
    if (!next.fire) return;
    const top = agents()
      .filter((a) => this.mem[a.address]?.bytes != null)
      .sort((a, b) => this.mem[b.address].bytes - this.mem[a.address].bytes)[0];
    const limit = this.slice.high ?? this.slice.max;
    let body = `${fmt(this.slice.current)} of ${fmt(limit)} (${pct.toFixed(0)}%)`;
    if (top) body += ` · largest: ${top.tab_name || top.space_name} (${this.label(top.address)})`;
    const note = { title: "Agents near memory budget", body, level: "warning" };
    if (top) note.action = { name: "pane.focus", args: { pane: top.pane } };  // click: go to it
    notify(note);
  }

  label(address) {
    const m = this.mem[address];
    if (m?.remote) return "remote";
    if (m?.bytes == null) return "–";
    return (m.approx ? "~" : "") + fmt(m.bytes);
  }

  header(t) {
    const s = this.slice;
    const pct = budgetPercent(s);
    if (!s || s.current == null) {
      return v_flex().gap(2).px(12).py(10).border_b(1).border_color(t.border)
        .child(div().text_size(12.5).font_semibold().text_color(t.foreground).child("Agent memory"))
        .child(div().text_size(11).text_color(t.dim).child("Shared budget not active"));
    }
    const limit = s.high ?? s.max;
    const color = pct == null ? t.accent : pct >= ALERT_PERCENT ? t.blocked : pct >= 60 ? t.working : t.done;
    const barWidth = Math.max(0, this.width - 24);
    const fill = pct == null ? 0 : Math.min(1, pct / 100) * barWidth;
    return v_flex().gap(6).px(12).py(10).border_b(1).border_color(t.border)
      .child(h_flex().items_center().justify_between()
        .child(div().text_size(12.5).font_semibold().text_color(t.foreground).child("Agent memory"))
        .child(div().text_size(12.5).font_semibold().text_color(color)
          .child(limit ? `${fmt(s.current)} / ${fmt(limit)}` : fmt(s.current))))
      .when(limit != null, (el) => el.child(
        div().w(barWidth).h(5).rounded(3).bg(t.raised).child(div().w(fill).h(5).rounded(3).bg(color))))
      .child(div().text_size(10.5).text_color(t.dim).child(
        [pct != null ? `${pct.toFixed(0)}% of ${s.high ? "throttle" : "limit"}` : null,
         s.max && s.high ? `max ${fmt(s.max)}` : null,
         s.cache ? `+${fmt(s.cache)} reclaimable cache` : null].filter(Boolean).join(" · ")));
  }

  row(a, t, max) {
    const m = this.mem[a.address];
    const share = m?.bytes != null && max > 0 ? m.bytes / max : 0;
    const where = a.tab_name && a.tab_name !== a.space_name ? `${a.space_name} · ${a.tab_name}` : a.space_name;
    return v_flex().id(`mem-${a.address}`).px(12).py(6).gap(3).cursor_pointer()
      .when(a.focused, (el) => el.bg(t.selected))
      .hover((s) => s.bg(t.hover))
      .on_click(() => run("pane.focus", { pane: a.pane }))
      .child(h_flex().gap(8).items_center()
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.foreground).child(where || a.address))
        .child(div().flex_none().text_size(12).font_medium()
          .text_color(m?.approx || m?.remote ? t.muted : t.foreground).child(this.label(a.address))))
      .child(h_flex().gap(8).items_center()
        .child(div().flex_1().min_w(0).truncate().text_size(10.5).text_color(t.dim).child(a.program?.name ?? a.app ?? ""))
        .child(div().flex_none().w(60).h(3).rounded(2).bg(t.raised)
          .child(div().w(60 * share).h(3).rounded(2).bg(t.accent))));
  }

  render() {
    const t = theme();
    const list = agents().slice().sort((a, b) => (this.mem[b.address]?.bytes ?? -1) - (this.mem[a.address]?.bytes ?? -1));
    const max = Math.max(0, ...list.map((a) => this.mem[a.address]?.bytes ?? 0));
    return v_flex().id("root").size_full().bg(t.chrome).text_color(t.foreground)
      .on_size_change((size, cx) => { if (Math.abs(size.width - this.width) >= 1) { this.width = size.width; cx.notify(); } })
      .child(this.header(t))
      .child(v_flex().flex_1().min_h(0).overflow_y_scrollbar().py(4)
        .when(list.length === 0, (el) => el.child(div().px(12).py(8).text_size(11.5).text_color(t.dim).child("No agents running")))
        .children(list.map((a) => this.row(a, t, max))))
      .when(Boolean(this.error), (el) => el.child(
        div().px(12).py(6).border_t(1).border_color(t.border).text_size(10.5).text_color(t.blocked).child(this.error)))
      .when(list.some((a) => this.mem[a.address]?.approx), (el) => el.child(
        div().px(12).py(6).border_t(1).border_color(t.border).text_size(10).text_color(t.dim)
          .child("~ not in a container: resident memory, approximate")));
  }
}
