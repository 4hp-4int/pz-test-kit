// PZRadar: a small polygon ("radar") chart as inline SVG, shared by the
// Workbench panels and the Studio rows. One shape in the accent colour (now),
// an optional ghost shape (before) dashed and unfilled, so the change reads as
// the shape moving and never relies on colour alone (dataviz: emphasis form;
// accent vs muted validated on the dark panel surface: CVD dE 16.2, contrast
// >= 3:1). Per-axis hover via <title>; numbers live in the tooltip and the
// values table, not on the plot.
//
//   PZRadar.svg(spec, before, { size })
//   spec   = { axes: [ { key, label, value (0..max), hint? } ], max = 1 }
//   before = the same shape for an earlier moment, or null
//   PZRadar.table(spec, before) -> <table> of the values (the table view)
(function () {
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const num = (v) => (typeof v === "number" && isFinite(v) ? v : 0);
  const fmt = (v) => (Math.round(num(v) * 100) / 100).toString();

  function points(spec, cx, cy, r) {
    const axes = spec.axes || [], max = spec.max || 1, n = axes.length || 1;
    return axes.map((a, i) => {
      const ang = -Math.PI / 2 + (2 * Math.PI * i) / n;
      const f = Math.max(0, Math.min(1, num(a.value) / max));
      return { a, ang, x: cx + Math.cos(ang) * r * f, y: cy + Math.sin(ang) * r * f };
    });
  }

  function svg(spec, before, opts) {
    const axes = (spec && spec.axes) || [];
    if (!axes.length) return "";
    const size = (opts && opts.size) || 180;
    const small = size < 130;
    const pad = small ? 12 : 30;
    const cx = size / 2, cy = size / 2, r = size / 2 - pad;
    const n = axes.length;
    const byKey = {};
    for (const a of (before && before.axes) || []) byKey[a.key] = a;
    let h = `<svg class="pzradar" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" role="img" aria-label="${esc(axes.map((a) => a.label + " " + fmt(a.value)).join(", "))}">`;
    // recessive grid: rings at quarters + spokes
    for (const t of [0.25, 0.5, 0.75, 1]) {
      const ring = axes.map((_, i) => {
        const ang = -Math.PI / 2 + (2 * Math.PI * i) / n;
        return `${(cx + Math.cos(ang) * r * t).toFixed(1)},${(cy + Math.sin(ang) * r * t).toFixed(1)}`;
      }).join(" ");
      h += `<polygon points="${ring}" fill="none" stroke="var(--line, #272c31)" stroke-width="1"/>`;
    }
    for (let i = 0; i < n; i++) {
      const ang = -Math.PI / 2 + (2 * Math.PI * i) / n;
      h += `<line x1="${cx}" y1="${cy}" x2="${(cx + Math.cos(ang) * r).toFixed(1)}" y2="${(cy + Math.sin(ang) * r).toFixed(1)}" stroke="var(--line, #272c31)" stroke-width="1"/>`;
    }
    // before: dashed ghost, no fill
    if (before && before.axes && before.axes.length) {
      const bp = points({ axes: axes.map((a) => byKey[a.key] || { key: a.key, value: 0 }), max: spec.max }, cx, cy, r);
      h += `<polygon points="${bp.map((p) => p.x.toFixed(1) + "," + p.y.toFixed(1)).join(" ")}" fill="none" stroke="var(--muted, #858c93)" stroke-width="1.5" stroke-dasharray="4 3"/>`;
    }
    // now: accent outline + light fill, markers ringed in the surface colour
    const pts = points(spec, cx, cy, r);
    h += `<polygon points="${pts.map((p) => p.x.toFixed(1) + "," + p.y.toFixed(1)).join(" ")}" fill="var(--accent, #d9a441)" fill-opacity="0.16" stroke="var(--accent, #d9a441)" stroke-width="2" stroke-linejoin="round"/>`;
    for (const p of pts) {
      if (!small) h += `<circle cx="${p.x.toFixed(1)}" cy="${p.y.toFixed(1)}" r="4" fill="var(--accent, #d9a441)" stroke="var(--panel, #15181b)" stroke-width="2"/>`;
      const was = byKey[p.a.key];
      const tip = `${p.a.label}: ${fmt(p.a.value)}${was ? " (was " + fmt(was.value) + ")" : ""}${p.a.hint ? " · " + p.a.hint : ""}`;
      h += `<circle cx="${p.x.toFixed(1)}" cy="${p.y.toFixed(1)}" r="${small ? 6 : 9}" fill="transparent"><title>${esc(tip)}</title></circle>`;
    }
    // axis labels at the rim, in text ink (never the series colour)
    if (!small) {
      for (let i = 0; i < n; i++) {
        const ang = -Math.PI / 2 + (2 * Math.PI * i) / n;
        const lx = cx + Math.cos(ang) * (r + 14), ly = cy + Math.sin(ang) * (r + 14) + 3;
        const anchor = Math.abs(Math.cos(ang)) < 0.2 ? "middle" : Math.cos(ang) > 0 ? "start" : "end";
        h += `<text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" text-anchor="${anchor}" font-size="10" fill="var(--muted, #858c93)"><title>${esc(axes[i].hint || axes[i].label)}</title>${esc(axes[i].label)}</text>`;
      }
    }
    h += `</svg>`;
    if (before && before.axes && before.axes.length && !small) {
      h += `<div class="pzradar-legend" style="font-size:11px;color:var(--muted,#858c93);display:flex;gap:12px;margin:2px 0 0 4px">
        <span><svg width="18" height="8"><line x1="0" y1="4" x2="18" y2="4" stroke="var(--accent,#d9a441)" stroke-width="2"/></svg> now</span>
        <span><svg width="18" height="8"><line x1="0" y1="4" x2="18" y2="4" stroke="var(--muted,#858c93)" stroke-width="1.5" stroke-dasharray="4 3"/></svg> before</span></div>`;
    }
    return h;
  }

  function table(spec, before) {
    const byKey = {};
    for (const a of (before && before.axes) || []) byKey[a.key] = a;
    return `<table>${((spec && spec.axes) || []).map((a) => `<tr><td class="k">${esc(a.label)}</td><td class="mono">${fmt(a.value)}${byKey[a.key] ? ` <span class="dim">was ${fmt(byKey[a.key].value)}</span>` : ""}</td></tr>`).join("")}</table>`;
  }

  window.PZRadar = { svg, table };
})();
