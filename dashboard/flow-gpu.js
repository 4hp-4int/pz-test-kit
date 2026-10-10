// SousVide Flow: the GPU renderer (PixiJS v8, WebGL). flow.html owns the model
// (units, edges, positions, styles, the trail); this only draws it.
//
// - Retained, keyed scene: one display object per unit and it is PATCHED on
//   change (position, text, border), never rebuilt. A layout change tweens
//   units to their new places; new units grow out of the unit that held them
//   and removed ones shrink into the unit that now holds them.
// - On-demand frames: nothing renders while nothing changes. Tweens and the
//   agent's glow keep frames coming only while they run.
// - Level of detail: below LOD_K zoom, text is hidden (tiles become blocks).
// - Culling: units off screen are skipped (CullerPlugin).
/* global PIXI */
(function () {
  const LOD_K = 0.45, TWEEN_MS = 240;
  const toHex = (c) => {
    if (typeof c === "number") return c;
    c = String(c).trim();
    if (c[0] === "#") return parseInt(c.length === 4 ? c.slice(1).split("").map((x) => x + x).join("") : c.slice(1), 16);
    const m = /hsl\(\s*([\d.]+)\s*,?\s*([\d.]+)%\s*,?\s*([\d.]+)%/.exec(c);
    if (!m) return 0x888888;
    const h = +m[1] / 360, s = +m[2] / 100, l = +m[3] / 100;
    const f = (n) => { const k = (n + h * 12) % 12, a = s * Math.min(l, 1 - l); return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)))); };
    return (f(0) << 16) | (f(8) << 8) | f(4);
  };
  const ease = (t) => 1 - Math.pow(1 - t, 3);

  const G = {
    app: null, W: 230, H: 50, view: { x: 0, y: 0, k: 1 }, lod: true,
    units: new Map(),      // id -> { box, bg, ring, texts, x, y, tw, style, data }
    dying: new Map(),      // id -> obj, shrinking away
    edges: [], hot: null, newEdges: null, trail: null,
    stats: { ms: 0, fps: 0, frames: 0, t0: 0, units: 0, edges: 0 },
    scheduled: false, edgeFade: 1, onStats: null,
  };

  G.init = async function (el) {
    PIXI.extensions.add(PIXI.CullerPlugin);
    const app = new PIXI.Application();
    await app.init({ resizeTo: el, background: "#0e1012", antialias: true, autoDensity: true,
                     resolution: window.devicePixelRatio || 1, autoStart: false, preference: "webgl" });
    el.prepend(app.canvas);
    app.canvas.style.display = "block";
    PIXI.BitmapFont.install({ name: "FlowMono", resolution: Math.max(2, window.devicePixelRatio || 1), padding: 4, dynamicFill: true,
      chars: [[" ", "~"], "…▸→·×▾"], style: { fontFamily: "JetBrains Mono, Cascadia Mono, Consolas, monospace", fontSize: 28, fill: 0xffffff } });
    const world = new PIXI.Container();
    const layer = () => { const c = new PIXI.Container(); world.addChild(c); return c; };
    G.L = { halos: layer(), edges: layer(), hotEdges: layer(), trail: layer(), nodes: layer(), badges: layer() };
    G.edgeG = new PIXI.Graphics(); G.L.edges.addChild(G.edgeG);
    G.hotG = new PIXI.Graphics(); G.L.hotEdges.addChild(G.hotG);
    G.haloG = new PIXI.Graphics(); G.L.halos.addChild(G.haloG);
    G.trailG = new PIXI.Graphics(); G.L.trail.addChild(G.trailG);
    G.badgeG = new PIXI.Graphics(); G.L.badges.addChild(G.badgeG);
    G.badgeTexts = [];
    app.stage.addChild(world);
    G.world = world; G.app = app;
    new ResizeObserver(() => { app.resize(); G.invalidate(); }).observe(el);
    G.invalidate();
  };

  G.invalidate = function () {
    if (G.scheduled || !G.app) return;
    G.scheduled = true;
    requestAnimationFrame(G.frame);
  };

  // ── per-frame ───────────────────────────────────────────────────────────
  G.frame = function (now) {
    G.scheduled = false;
    if (G.beforeFrame) G.beforeFrame();          // flow.html flushes its batched model changes here
    let busy = false;
    // tweens
    for (const map of [G.units, G.dying]) for (const [id, u] of map) {
      if (!u.tw) continue;
      const t = Math.min(1, (now - u.tw.t0) / TWEEN_MS), e = ease(t);
      u.box.x = u.tw.x0 + (u.tw.x1 - u.tw.x0) * e;
      u.box.y = u.tw.y0 + (u.tw.y1 - u.tw.y0) * e;
      const s = u.tw.s0 + (u.tw.s1 - u.tw.s0) * e;
      u.box.scale.set(s);
      u.fade = u.tw.a0 + (u.tw.a1 - u.tw.a0) * e;
      u.box.alpha = u.fade * (u.dim ?? 1);
      if (t >= 1) { u.tw = null; if (map === G.dying) { u.box.destroy({ children: true }); G.dying.delete(id); } }
      else busy = true;
    }
    // edges fade back in after a layout move
    if (G.edgeFade < 1) {
      const anyTween = [...G.units.values()].some((u) => u.tw);
      if (!anyTween) { G.edgeFade = Math.min(1, G.edgeFade + 0.12); if (G.edgeFade < 1) busy = true; if (G.edgesDirty) G.drawEdges(); }
      else busy = true;
      G.L.edges.alpha = G.edgeFade * (G.hot ? 0.07 : 1);
      G.L.hotEdges.alpha = G.edgeFade; G.L.trail.alpha = G.edgeFade;
    }
    // the agent's glow pulses
    for (const u of G.units.values()) {
      if (!u.ring.visible) continue;
      const speed = u.glow === "editing" ? 0.011 : u.glow === "denied" ? 0.016 : 0.006;
      u.ring.alpha = 0.35 + 0.65 * Math.abs(Math.sin(now * speed));
      busy = true;
    }
    const t0 = performance.now();
    G.app.render();
    const ms = performance.now() - t0;
    const st = G.stats;
    st.ms = st.ms * 0.8 + ms * 0.2; st.frames++;
    if (now - st.t0 > 1000) { st.fps = Math.round(st.frames * 1000 / (now - st.t0)); st.frames = 0; st.t0 = now; }
    if (G.onStats) G.onStats(st, busy);
    if (busy) G.invalidate();
  };

  // ── view ────────────────────────────────────────────────────────────────
  G.setView = function (v) {
    G.view = v;
    if (!G.world) return;
    G.world.position.set(v.x, v.y); G.world.scale.set(v.k);
    const lod = v.k >= LOD_K;
    if (lod !== G.lod) { G.lod = lod; for (const u of G.units.values()) for (const t of u.texts) t.visible = lod; G.badgeTexts.forEach((t) => (t.visible = lod)); }
    G.invalidate();
  };
  G.screenToWorld = (sx, sy) => ({ x: (sx - G.view.x) / G.view.k, y: (sy - G.view.y) / G.view.k });
  G.hit = function (sx, sy) {
    const p = G.screenToWorld(sx, sy);
    for (const [id, u] of G.units) if (p.x >= u.x && p.x <= u.x + G.W && p.y >= u.y && p.y <= u.y + G.H) return id;
    return null;
  };

  // ── scene: units ────────────────────────────────────────────────────────
  function makeText(size, color) {
    const t = new PIXI.BitmapText({ text: "", style: { fontFamily: "FlowMono", fontSize: size } });
    t.tint = color; t.visible = G.lod;
    return t;
  }
  function makeUnit() {
    const box = new PIXI.Container();
    box.cullable = true; box.cullArea = new PIXI.Rectangle(-10, -10, G.W + 20, G.H + 20);
    const ring = new PIXI.Graphics(); ring.visible = false;
    const bg = new PIXI.Graphics();
    const label = makeText(11, 0xd5d8db), sub = makeText(9.5, 0x858c93), cnt = makeText(9.5, 0x5d646b), marks = makeText(9.5, 0xe0913c);
    label.position.set(12, 9); sub.position.set(12, 28); cnt.y = 28; marks.y = 6;
    box.addChild(ring, bg, label, sub, cnt, marks);
    return { box, bg, ring, texts: [label, sub, cnt, marks], label, sub, cnt, marks, x: 0, y: 0, tw: null, fade: 1, dim: 1, key: "" };
  }
  function dashedRect(g, x, y, w, h, dash, gap) {
    const side = (x0, y0, x1, y1) => {
      const len = Math.hypot(x1 - x0, y1 - y0), dx = (x1 - x0) / len, dy = (y1 - y0) / len;
      for (let d = 0; d < len; d += dash + gap) { const e = Math.min(len, d + dash); g.moveTo(x0 + dx * d, y0 + dy * d).lineTo(x0 + dx * e, y0 + dy * e); }
    };
    side(x, y, x + w, y); side(x + w, y, x + w, y + h); side(x + w, y + h, x, y + h); side(x, y + h, x, y);
  }
  // look: { color, group, fill, border:{color,width,dash}, dim, glow }
  function paint(u, look) {
    const key = JSON.stringify(look);
    if (key === u.key) return;
    u.key = key;
    const W = G.W, H = G.H, c = toHex(look.color), g = u.bg;
    g.clear();
    if (look.group) g.roundRect(4, 4, W, H, 6).fill(0x14171a).stroke({ width: 1.2, color: c, alpha: 0.45 });
    g.roundRect(0, 0, W, H, 6).fill(toHex(look.fill));
    const b = look.border;
    if (b.dash) { g.roundRect(0, 0, W, H, 6).stroke({ width: 1.2, color: c }); dashedRect(g, 0, 0, W, H, b.dash[0], b.dash[1]); g.stroke({ width: b.width, color: toHex(b.color) }); }
    else g.roundRect(0, 0, W, H, 6).stroke({ width: b.width, color: toHex(b.color) });
    g.rect(0, 0, 5, H).fill(c);
    if (look.task) g.rect(5, 0, W - 5, 3).fill(toHex(look.task));   // the task anchored here
    u.glow = look.glow;
    u.ring.clear();
    if (look.glow) {
      const gc = { reading: 0x7fb2e0, editing: 0xe0913c, denied: 0xe05050 }[look.glow];
      u.ring.roundRect(-5, -5, W + 10, H + 10, 10).stroke({ width: 5, color: gc });
      u.ring.visible = true;
    } else u.ring.visible = false;
    u.dim = look.dim;
    if (!u.tw) u.box.alpha = u.fade * u.dim;
  }
  function setText(t, s) { if (t.text !== s) t.text = s; }

  // scene = { units: [{ id, x, y, label, sub, cnt, marks, marksColor, look }], from(id) -> {x,y}|null, into(id) -> {x,y}|null }
  G.syncScene = function (scene, animate) {
    const now = performance.now();
    const seen = new Set();
    for (const s of scene.units) {
      seen.add(s.id);
      let u = G.units.get(s.id);
      const born = !u;
      if (born) {
        u = G.dying.get(s.id);
        if (u) { G.dying.delete(s.id); } else { u = makeUnit(); G.L.nodes.addChild(u.box); }
        G.units.set(s.id, u);
      }
      setText(u.label, s.label); setText(u.sub, s.sub); setText(u.cnt, s.cnt); setText(u.marks, s.marks || "");
      u.cnt.x = G.W - 8 - u.cnt.width; u.marks.x = G.W - 8 - u.marks.width; u.marks.tint = toHex(s.marksColor || "#e0913c");
      paint(u, s.look);
      const moved = u.x !== s.x || u.y !== s.y;
      if (animate && (born || moved)) {
        const src = born ? (scene.from(s.id) || { x: s.x, y: s.y }) : { x: u.box.x, y: u.box.y };
        u.tw = { t0: now, x0: src.x, y0: src.y, x1: s.x, y1: s.y, s0: born ? 0.25 : u.box.scale.x, s1: 1, a0: born ? 0 : u.fade, a1: 1 };
      } else if (!u.tw) { u.box.position.set(s.x, s.y); u.box.scale.set(1); u.fade = 1; u.box.alpha = u.dim; }
      u.x = s.x; u.y = s.y;
    }
    for (const [id, u] of G.units) {
      if (seen.has(id)) continue;
      G.units.delete(id);
      const dst = animate && scene.into(id);
      if (dst) { u.tw = { t0: now, x0: u.box.x, y0: u.box.y, x1: dst.x, y1: dst.y, s0: u.box.scale.x, s1: 0.25, a0: u.fade, a1: 0 }; G.dying.set(id, u); }
      else u.box.destroy({ children: true });
    }
    G.stats.units = G.units.size;
    if (animate) { G.edgeFade = 0; G.L.edges.alpha = 0; G.L.hotEdges.alpha = 0; G.L.trail.alpha = 0; }
    G.invalidate();
  };

  // ── edges ───────────────────────────────────────────────────────────────
  const EDGE = { call: [0x4a525a, null], http: [0x7fb2e0, [7, 4]], sql: [0x5fb36b, null], file: [0xb8c0c8, [2, 4]], mirror: [0xd9a441, [3, 3]] };
  function curve(e) {
    const a = G.units.get(e.from), b = G.units.get(e.to);
    if (!a || !b) return null;
    const W = G.W, H = G.H, x1 = a.x + W, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2;
    if (x2 > x1) { const mx = (x1 + x2) / 2; return [x1, y1, mx, y1, mx, y2, x2, y2]; }
    return [x1, y1, x1 + 80, y1 - 60, x2 - 80, y2 - 60, x2, y2];
  }
  function bez(c, t) {
    const u = 1 - t;
    return [u * u * u * c[0] + 3 * u * u * t * c[2] + 3 * u * t * t * c[4] + t * t * t * c[6],
            u * u * u * c[1] + 3 * u * u * t * c[3] + 3 * u * t * t * c[5] + t * t * t * c[7]];
  }
  function strokeEdge(g, e, color, width, alpha, dash, arrow) {
    const c = curve(e); if (!c) return;
    if (!dash) g.moveTo(c[0], c[1]).bezierCurveTo(c[2], c[3], c[4], c[5], c[6], c[7]).stroke({ width, color, alpha });
    else {
      const N = 48, pts = []; for (let i = 0; i <= N; i++) pts.push(bez(c, i / N));
      let carry = 0, on = true, left = dash[0];
      for (let i = 1; i < pts.length; i++) {
        let [ax, ay] = pts[i - 1]; const [bx, by] = pts[i];
        let seg = Math.hypot(bx - ax, by - ay);
        while (seg > 0) {
          const step = Math.min(seg, left), r = step / seg, nx = ax + (bx - ax) * r, ny = ay + (by - ay) * r;
          if (on) g.moveTo(ax, ay).lineTo(nx, ny);
          ax = nx; ay = ny; seg -= step; left -= step;
          if (left <= 0) { on = !on; left = on ? dash[0] : dash[1]; }
        }
      }
      g.stroke({ width, color, alpha });
    }
    if (arrow) {
      const [px, py] = bez(c, 0.97), ang = Math.atan2(c[7] - py, c[6] - px), s = 4 + width;
      g.poly([c[6], c[7], c[6] - s * Math.cos(ang - 0.45), c[7] - s * Math.sin(ang - 0.45), c[6] - s * Math.cos(ang + 0.45), c[7] - s * Math.sin(ang + 0.45)]).fill({ color, alpha });
    }
  }
  // edges = [{ from, to, kind, w }]
  G.setEdges = function (edges) { G.edges = edges; G.stats.edges = edges.length; G.edgesDirty = true; if (G.edgeFade >= 1) G.drawEdges(); G.invalidate(); };
  G.drawEdges = function () {
    G.edgesDirty = false;
    const g = G.edgeG; g.clear();
    for (const e of G.edges) { const [col, dash] = EDGE[e.kind || "call"] || EDGE.call; strokeEdge(g, e, col, e.w, 1, dash, e.kind !== "mirror"); }
    G.drawHot();
  };
  // hot = Set of "from|to|kind" to draw bright (selection), fresh = same for new edges (green)
  G.setHighlight = function (hot, fresh) { G.hot = hot; G.newEdges = fresh; G.drawHot(); G.invalidate(); };
  G.drawHot = function () {
    const g = G.hotG; g.clear();
    G.L.edges.alpha = G.edgeFade * (G.hot ? 0.07 : 1);
    for (const e of G.edges) {
      const k = `${e.from}|${e.to}|${e.kind || "call"}`;
      if (G.newEdges && G.newEdges.has(k)) strokeEdge(g, e, 0x5fb36b, e.w + 1.4, 1, null, true);
      else if (G.hot && G.hot.has(k)) { const dash = (EDGE[e.kind || "call"] || EDGE.call)[1]; strokeEdge(g, e, 0xd9a441, e.w + 0.4, 0.95, dash, e.kind !== "mirror"); }
    }
  };

  // ── trail ───────────────────────────────────────────────────────────────
  // trail = { halos: [{ id, color, alpha }], paths: [{ a, b, alpha, width }], badges: [{ id, n, color, alpha }] }
  G.setTrail = function (trail) {
    G.trail = trail;
    const hg = G.haloG, tg = G.trailG, bg = G.badgeG;
    hg.clear(); tg.clear(); bg.clear();
    const W = G.W, H = G.H;
    let used = 0;
    if (trail) {
      for (const h of trail.halos) { const u = G.units.get(h.id); if (u) hg.roundRect(u.x - 7, u.y - 7, W + 14, H + 14, 11).fill({ color: toHex(h.color), alpha: h.alpha }); }
      for (const p of trail.paths) {
        const a = G.units.get(p.a), b = G.units.get(p.b); if (!a || !b || a === b) continue;
        const ax = a.x + W / 2, ay = a.y + H / 2, bx = b.x + W / 2, by = b.y + H / 2;
        const mx = (ax + bx) / 2, my = (ay + by) / 2 - Math.min(80, Math.abs(bx - ax) * 0.15 + 20);
        tg.moveTo(ax, ay).quadraticCurveTo(mx, my, bx, by).stroke({ width: p.width, color: 0xf0e6c8, alpha: p.alpha, cap: "round" });
        const ang = Math.atan2(by - my, bx - mx), s = 5 + p.width;
        tg.poly([bx, by, bx - s * Math.cos(ang - 0.45), by - s * Math.sin(ang - 0.45), bx - s * Math.cos(ang + 0.45), by - s * Math.sin(ang + 0.45)]).fill({ color: 0xf0e6c8, alpha: p.alpha });
      }
      for (const b of trail.badges) {
        const u = G.units.get(b.id); if (!u) continue;
        bg.circle(u.x, u.y, 9).fill({ color: toHex(b.color), alpha: b.alpha }).stroke({ width: 1.5, color: 0x0e1012, alpha: b.alpha });
        let t = G.badgeTexts[used];
        if (!t) { t = makeText(9, 0x0e1012); G.L.badges.addChild(t); G.badgeTexts.push(t); }
        setText(t, String(b.n)); t.alpha = b.alpha; t.visible = G.lod;
        t.position.set(u.x - t.width / 2, u.y - 6); used++;
      }
    }
    for (let i = used; i < G.badgeTexts.length; i++) G.badgeTexts[i].visible = false;
    G.invalidate();
  };

  window.FlowGPU = G;
})();
