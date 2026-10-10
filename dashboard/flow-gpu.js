// SousVide Flow: the GPU renderer (PixiJS v8, WebGL). flow.html owns the model
// (the nested layout, what is shown at this zoom, styles, the trail); this
// only draws it.
//
// - Retained, keyed scene: one display object per unit, PATCHED on change
//   (position, size, text, border), never rebuilt. A layout change tweens.
// - Three kinds of unit: a CARD (a block, world-sized text), a FRAME (an open
//   container: area or file, drawn under everything with its header), and a
//   CLOSED container (one card standing for all it holds). Container headers
//   keep a readable size on screen at any zoom (counter-scaled text).
// - On-demand frames: nothing renders while nothing changes.
// - Level of detail: below LOD_K zoom, card text is hidden; culling skips
//   off-screen units.
/* global PIXI */
(function () {
  const LOD_K = 0.38, TWEEN_MS = 240;
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
    app: null, W: 300, H: 88, view: { x: 0, y: 0, k: 1 }, lod: true,
    units: new Map(),      // id -> { box, bg, ring, kind, x, y, w, h, tw, ... }
    dying: new Map(),
    edges: [], hot: null, newEdges: null, trail: null,
    stats: { ms: 0, fps: 0, frames: 0, t0: 0, units: 0, edges: 0 },
    scheduled: false, edgeFade: 1, onStats: null, headK: 0,
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
    // headers: a proportional face, read as prose (titles and purpose lines)
    PIXI.BitmapFont.install({ name: "FlowSans", resolution: Math.max(2, window.devicePixelRatio || 1), padding: 4, dynamicFill: true,
      chars: [[" ", "~"], "…▸→·×▾’—"], style: { fontFamily: "Segoe UI, system-ui, sans-serif", fontSize: 32, fill: 0xffffff } });
    const world = new PIXI.Container();
    const layer = () => { const c = new PIXI.Container(); world.addChild(c); return c; };
    G.L = { frames: layer(), halos: layer(), edges: layer(), hotEdges: layer(), trail: layer(), nodes: layer(), badges: layer(), pins: layer() };
    G.pinPool = []; G.pins = [];
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
    if (G.beforeFrame) G.beforeFrame();
    if (G.headersDirty) { G.headersDirty = false; G.headK = G.view.k; for (const u of G.units.values()) if (u.kind !== "card") layHeader(u); }
    let busy = false;
    for (const map of [G.units, G.dying]) for (const [id, u] of map) {
      if (!u.tw) continue;
      const t = Math.min(1, (now - u.tw.t0) / TWEEN_MS), e = ease(t);
      u.box.x = u.tw.x0 + (u.tw.x1 - u.tw.x0) * e;
      u.box.y = u.tw.y0 + (u.tw.y1 - u.tw.y0) * e;
      u.fade = u.tw.a0 + (u.tw.a1 - u.tw.a0) * e;
      u.box.alpha = u.fade * (u.dim ?? 1);
      if (t >= 1) { u.tw = null; if (map === G.dying) { u.box.destroy({ children: true }); G.dying.delete(id); } }
      else busy = true;
    }
    if (G.edgeFade < 1) {
      const anyTween = [...G.units.values()].some((u) => u.tw);
      if (!anyTween) { G.edgeFade = Math.min(1, G.edgeFade + 0.12); if (G.edgeFade < 1) busy = true; if (G.edgesDirty) G.drawEdges(); }
      else busy = true;
      G.L.edges.alpha = G.edgeFade * (G.hot ? 0.12 : 1);
      G.L.hotEdges.alpha = G.edgeFade; G.L.trail.alpha = G.edgeFade;
    }
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
    if (lod !== G.lod) {
      G.lod = lod;
      for (const u of G.units.values()) if (u.kind === "card") for (const t of u.texts) t.visible = lod;
      G.badgeTexts.forEach((t) => (t.visible = lod));
    }
    // container headers keep their screen size: re-set them when the zoom moved
    if (Math.abs(v.k - G.headK) / Math.max(G.headK, 0.001) > 0.03) G.headersDirty = true;   // laid out once, in the frame
    G.layoutPins();
    G.invalidate();
  };
  G.screenToWorld = (sx, sy) => ({ x: (sx - G.view.x) / G.view.k, y: (sy - G.view.y) / G.view.k });
  // the deepest unit under the point (a card over the frame that holds it),
  // and whether the point is on a container's collapse chevron
  G.hit = function (sx, sy) {
    const p = G.screenToWorld(sx, sy);
    let best = null, bestA = Infinity;
    for (const [id, u] of G.units) {
      if (p.x < u.x || p.x > u.x + u.w || p.y < u.y || p.y > u.y + u.h) continue;
      const a = u.w * u.h;
      if (a < bestA) { best = id; bestA = a; }
    }
    G.lastPart = null;
    const u = best && G.units.get(best);
    if (u && u.kind !== "card") {
      const s = Math.max(1, 1 / G.view.k), cw = 34 * s;
      if (p.x > u.x + u.w - cw && p.y < u.y + cw) G.lastPart = "chevron";
      else if (u.kind === "frame" && p.y < u.y + (u.hh || 100)) G.lastPart = "header";
    }
    return best;
  };

  // ── scene: units ────────────────────────────────────────────────────────
  function makeText(size, color, font) {
    const t = new PIXI.BitmapText({ text: "", style: { fontFamily: font || "FlowMono", fontSize: size } });
    t.tint = color; t.visible = G.lod;
    return t;
  }
  function makeCard() {
    const box = new PIXI.Container();
    box.cullable = true;
    const ring = new PIXI.Graphics(); ring.visible = false;
    const bg = new PIXI.Graphics();
    const label = makeText(13, 0xe6e9ec, "FlowSans"), sub = makeText(9.5, 0x6b737b), cnt = makeText(9.5, 0x5d646b), marks = makeText(9.5, 0xe0913c);
    const body = new PIXI.BitmapText({ text: "", style: { fontFamily: "FlowSans", fontSize: 11, wordWrap: true, wordWrapWidth: G.W - 26, lineHeight: 14 } });
    body.tint = 0xa4abb2; body.visible = G.lod;
    label.position.set(12, 7); sub.position.set(12, 25); body.position.set(12, 40); cnt.y = G.H - 15; marks.y = 7;
    box.addChild(ring, bg, label, sub, body, cnt, marks);
    return { kind: "card", box, bg, ring, texts: [label, sub, body, cnt, marks], label, sub, body, cnt, marks, x: 0, y: 0, w: G.W, h: G.H, tw: null, fade: 1, dim: 1, key: "" };
  }
  // a container: its header (title, what kind and how big, purpose) keeps a
  // readable size on screen; a chevron collapses or expands it
  function makeContainer(kind) {
    const box = new PIXI.Container();
    box.cullable = true;
    const ring = new PIXI.Graphics(); ring.visible = false;
    const bg = new PIXI.Graphics();
    const label = makeText(16, 0xeef0f2, "FlowSans"), sub = makeText(10.5, 0x7b838b), marks = makeText(10.5, 0xe0913c), chev = makeText(16, 0x9aa3ab, "FlowSans");
    const body = new PIXI.BitmapText({ text: "", style: { fontFamily: "FlowSans", fontSize: 13, wordWrap: true, wordWrapWidth: 300, lineHeight: 17 } });
    body.tint = 0xb0b7be;
    for (const t of [label, sub, marks, chev, body]) t.visible = true;
    box.addChild(ring, bg, label, sub, body, marks, chev);
    return { kind, box, bg, ring, texts: [label, sub, body, marks, chev], label, sub, body, marks, chev, x: 0, y: 0, w: 1, h: 1, tw: null, fade: 1, dim: 1, key: "", hs: 0 };
  }
  // a label never leaves its box: measured at its scale, cut with "…", or dropped
  // (t.width already includes the text's scale in Pixi v8)
  function fit(t, full, maxW) {
    t.text = full;
    if (t.width <= maxW) return true;
    let n = Math.floor(full.length * maxW / t.width) - 1;
    for (let i = 0; i < 4 && n > 2; i++) {
      t.text = full.slice(0, n).trimEnd() + "…";
      if (t.width <= maxW) return true;
      n -= Math.max(1, Math.ceil(n * 0.12));
    }
    t.text = ""; return false;
  }
  function layHeader(u) {
    const k = G.view.k, s = Math.max(1, 1 / k);
    const screenW = u.w * k;
    const show = screenW > 54;
    for (const t of u.texts) { t.visible = show; t.scale.set(s); }
    u.marks.visible = false;                                   // folded into the meta line
    if (!show) return;
    const pad = 14 * s, chevW = 30 * s, inner = u.w - pad - chevW;   // world units the header may use
    u.label.position.set(pad, 10 * s);
    u.sub.position.set(pad, 33 * s);
    u.chev.position.set(u.w - 24 * s, 9 * s);
    u.chev.visible = screenW > 120;
    fit(u.label, u.fullLabel || u.label.text, inner, s);
    u.sub.visible = screenW > 150 && fit(u.sub, u.fullSub || u.sub.text, u.w - 2 * pad, s);
    const wrap = Math.max(60, screenW - 2 * 14 - 8);
    if (Math.abs((u.body.style.wordWrapWidth || 0) - wrap) > 4) u.body.style.wordWrapWidth = wrap;
    u.body.position.set(pad, 54 * s);
    const room = u.kind === "closed" ? u.h : (u.hh || 100);
    u.body.visible = screenW > 170 && (54 * s + u.body.height) < room - 6 * s;
  }
  function dashedRect(g, x, y, w, h, dash, gap) {
    const side = (x0, y0, x1, y1) => {
      const len = Math.hypot(x1 - x0, y1 - y0), dx = (x1 - x0) / len, dy = (y1 - y0) / len;
      for (let d = 0; d < len; d += dash + gap) { const e = Math.min(len, d + dash); g.moveTo(x0 + dx * d, y0 + dy * d).lineTo(x0 + dx * e, y0 + dy * e); }
    };
    side(x, y, x + w, y); side(x + w, y, x + w, y + h); side(x + w, y + h, x, y + h); side(x, y + h, x, y);
  }
  // look: { color, fill, border:{color,width,dash}, dim, glow, task, ghost }
  function paint(u, look) {
    const key = JSON.stringify(look) + u.w + "x" + u.h + u.kidsKey;
    if (key === u.key) return;
    u.key = key;
    const W = u.w, H = u.h, c = toHex(look.color), g = u.bg;
    g.clear();
    const r = u.kind === "card" ? 6 : 10;
    if (u.kind === "frame") {
      // an open container: a quiet frame under its contents, a header band on top
      g.roundRect(0, 0, W, H, r).fill({ color: 0x111417, alpha: 0.92 }).stroke({ width: look.border.width + 0.6, color: toHex(look.border.color), alpha: 0.85 });
      g.roundRect(0, 0, W, Math.min(H, u.hh || 100), r).fill({ color: c, alpha: 0.10 });
      g.rect(0, 0, 6, H).fill({ color: c, alpha: 0.9 });
    } else {
      g.roundRect(0, 0, W, H, r).fill(toHex(look.fill));
      if (u.kids) for (const [kx, ky, kw, kh] of u.kids) g.roundRect(kx, ky, kw, kh, 6).fill({ color: c, alpha: 0.03 }).stroke({ width: 1, color: c, alpha: 0.13 });
      const b = look.border;
      if (b.dash) { if (!look.ghost) g.roundRect(0, 0, W, H, r).stroke({ width: 1.2, color: c }); dashedRect(g, 0, 0, W, H, b.dash[0], b.dash[1]); g.stroke({ width: b.width, color: toHex(b.color) }); }
      else g.roundRect(0, 0, W, H, r).stroke({ width: u.kind === "closed" ? b.width + 1 : b.width, color: toHex(b.color) });
      g.rect(0, 0, u.kind === "closed" ? 8 : 5, H).fill(c);
    }
    if (look.task) g.rect(6, 0, W - 6, u.kind === "card" ? 3 : 5).fill(toHex(look.task));
    u.glow = look.glow;
    u.ring.clear();
    if (look.glow) {
      const gc = { reading: 0x7fb2e0, editing: 0xe0913c, denied: 0xe05050 }[look.glow];
      u.ring.roundRect(-5, -5, W + 10, H + 10, r + 4).stroke({ width: u.kind === "card" ? 5 : 8, color: gc });
      u.ring.visible = true;
    } else u.ring.visible = false;
    u.dim = look.dim;
    if (!u.tw) u.box.alpha = u.fade * u.dim;
  }
  function setText(t, s) { if (t.text !== s) t.text = s; }

  // scene = { units: [{ id, kind, x, y, w, h, hh, label, sub, body, cnt, marks, marksColor, chev, look }], from(id), into(id) }
  G.syncScene = function (scene, animate) {
    const now = performance.now();
    const seen = new Set();
    for (const s of scene.units) {
      seen.add(s.id);
      let u = G.units.get(s.id);
      if (u && u.kind !== s.kind) { u.box.destroy({ children: true }); G.units.delete(s.id); u = null; }   // opened or closed: a new body
      const born = !u;
      if (born) {
        u = G.dying.get(s.id);
        if (u && u.kind === s.kind) G.dying.delete(s.id);
        else { u = s.kind === "card" ? makeCard() : makeContainer(s.kind); (s.kind === "frame" ? G.L.frames : G.L.nodes).addChild(u.box); }
        G.units.set(s.id, u);
      }
      u.w = s.w; u.h = s.h; u.hh = s.hh; u.kids = s.kids || null;
      u.kidsKey = u.kids ? u.kids.length + ":" + (u.kids[0] || []).join(",") : "";
      u.box.cullArea = new PIXI.Rectangle(-12, -12, s.w + 24, s.h + 24);
      setText(u.label, s.label); setText(u.sub, s.sub); setText(u.body, s.body || ""); setText(u.marks, s.marks || "");
      u.marks.tint = toHex(s.marksColor || "#e0913c");
      if (u.kind === "card") { setText(u.cnt, s.cnt); u.cnt.x = G.W - 8 - u.cnt.width; u.marks.x = G.W - 8 - u.marks.width;
        fit(u.label, s.label, G.W - 24 - (s.marks ? u.marks.width + 8 : 0), 1); fit(u.sub, s.sub, G.W - 24 - u.cnt.width - 8, 1); }
      else { u.fullLabel = s.label; u.fullSub = s.sub; setText(u.chev, s.chev || ""); layHeader(u); }
      paint(u, s.look);
      const moved = u.x !== s.x || u.y !== s.y;
      if (animate && (born || moved)) {
        const src = born ? (scene.from(s.id) || { x: s.x, y: s.y }) : { x: u.box.x, y: u.box.y };
        u.tw = { t0: now, x0: src.x, y0: src.y, x1: s.x, y1: s.y, a0: born ? 0 : u.fade, a1: 1 };
      } else if (!u.tw) { u.box.position.set(s.x, s.y); u.fade = 1; u.box.alpha = u.dim; }
      u.x = s.x; u.y = s.y;
    }
    for (const [id, u] of G.units) {
      if (seen.has(id)) continue;
      G.units.delete(id);
      const dst = animate && scene.into(id);
      if (dst) { u.tw = { t0: now, x0: u.box.x, y0: u.box.y, x1: dst.x, y1: dst.y, a0: u.fade, a1: 0 }; G.dying.set(id, u); }
      else u.box.destroy({ children: true });
    }
    G.stats.units = G.units.size;
    if (animate) { G.edgeFade = 0; G.L.edges.alpha = 0; G.L.hotEdges.alpha = 0; G.L.trail.alpha = 0; }
    G.invalidate();
  };

  // ── edges ───────────────────────────────────────────────────────────────
  const EDGE = { call: [0x58616a, null], http: [0x7fb2e0, [7, 4]], sql: [0x5fb36b, null], file: [0xb8c0c8, [2, 4]], mirror: [0xd9a441, [3, 3]], sketch: [0x9aa3ab, [4, 4]] };
  function curve(e) {
    const a = G.units.get(e.from), b = G.units.get(e.to);
    if (!a || !b) return null;
    const ay = a.y + Math.min(a.h / 2, 44), by = b.y + Math.min(b.h / 2, 44);
    // leave from the side facing the other end
    if (b.x >= a.x + a.w) { const x1 = a.x + a.w, x2 = b.x, mx = (x1 + x2) / 2; return [x1, ay, mx, ay, mx, by, x2, by]; }
    if (b.x + b.w <= a.x) { const x1 = a.x, x2 = b.x + b.w, mx = (x1 + x2) / 2; return [x1, ay, mx, ay, mx, by, x2, by]; }
    // stacked: leave from the bottom, arrive at the top (or the other way)
    const ax = a.x + a.w / 2, bx = b.x + b.w / 2;
    if (b.y >= a.y + a.h) { const y1 = a.y + a.h, y2 = b.y, my = (y1 + y2) / 2; return [ax, y1, ax, my, bx, my, bx, y2]; }
    const y1 = a.y, y2 = b.y + b.h, my = (y1 + y2) / 2; return [ax, y1, ax, my, bx, my, bx, y2];
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
      let on = true, left = dash[0];
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
  // edges = [{ from, to, kind, w, faint }]
  G.setEdges = function (edges) { G.edges = edges; G.stats.edges = edges.length; G.edgesDirty = true; if (G.edgeFade >= 1) G.drawEdges(); G.invalidate(); };
  G.drawEdges = function () {
    G.edgesDirty = false;
    const g = G.edgeG; g.clear();
    for (const e of G.edges) { const [col, dash] = EDGE[e.kind || "call"] || EDGE.call; strokeEdge(g, e, col, e.w, e.faint ? 0.35 : 1, dash, e.kind !== "mirror"); }
    G.drawHot();
  };
  G.setHighlight = function (hot, fresh) { G.hot = hot; G.newEdges = fresh; G.drawHot(); G.invalidate(); };
  G.drawHot = function () {
    const g = G.hotG; g.clear();
    G.L.edges.alpha = G.edgeFade * (G.hot ? 0.12 : 1);
    for (const e of G.edges) {
      const k = `${e.from}|${e.to}|${e.kind || "call"}`;
      if (G.newEdges && G.newEdges.has(k)) strokeEdge(g, e, 0x5fb36b, e.w + 1.4, 1, null, true);
      else if (G.hot && G.hot.has(k)) { const dash = (EDGE[e.kind || "call"] || EDGE.call)[1]; strokeEdge(g, e, 0xd9a441, e.w + 0.6, 0.95, dash, e.kind !== "mirror"); }
    }
  };

  // ── trail ───────────────────────────────────────────────────────────────
  G.setTrail = function (trail) {
    G.trail = trail;
    const hg = G.haloG, tg = G.trailG, bg = G.badgeG;
    hg.clear(); tg.clear(); bg.clear();
    let used = 0;
    if (trail) {
      for (const h of trail.halos) { const u = G.units.get(h.id); if (u) hg.roundRect(u.x - 7, u.y - 7, u.w + 14, Math.min(u.h, 400) + 14, 11).fill({ color: toHex(h.color), alpha: h.alpha * (u.kind === "card" ? 1 : 0.6) }); }
      for (const p of trail.paths) {
        const a = G.units.get(p.a), b = G.units.get(p.b); if (!a || !b || a === b) continue;
        const ax = a.x + a.w / 2, ay = a.y + Math.min(a.h / 2, 44), bx = b.x + b.w / 2, by = b.y + Math.min(b.h / 2, 44);
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

  // ── pins: task labels over their main unit, the same size at every zoom ──
  G.setPins = function (pins) { G.pins = pins || []; G.layoutPins(); G.invalidate(); };
  G.layoutPins = function () {
    if (!G.L) return;
    const s = Math.min(2.5, Math.max(1, 1 / G.view.k));
    const placed = [];
    let used = 0;
    for (const p of G.pins) {
      const u = G.units.get(p.id); if (!u) continue;
      let pin = G.pinPool[used];
      if (!pin) {
        pin = { box: new PIXI.Container(), bg: new PIXI.Graphics(), text: makeText(10.5, 0xd5d8db), key: "" };
        pin.text.visible = true; pin.text.position.set(10, 3);
        pin.box.addChild(pin.bg, pin.text); G.L.pins.addChild(pin.box); G.pinPool.push(pin);
      }
      const key = p.text + p.color + p.active;
      if (key !== pin.key) {
        pin.key = key; setText(pin.text, p.text);
        const w = pin.text.width + 18, c = toHex(p.color);
        pin.bg.clear().roundRect(0, 0, w, 19, 5).fill({ color: 0x15181b, alpha: 0.96 }).stroke({ width: p.active ? 2 : 1, color: c });
        pin.bg.rect(0, 0, 5, 19).fill(c);
      }
      const r = { x: u.x + 4, y: u.y - (p.row + 1) * 22 * s, w: (pin.text.width + 18) * s, h: 19 * s };
      const clash = placed.some((q) => r.x < q.x + q.w && q.x < r.x + r.w && r.y < q.y + q.h && q.y < r.y + r.h);
      pin.box.visible = !clash; pin.text.visible = true;
      if (!clash) placed.push(r);
      pin.box.scale.set(s);
      pin.box.position.set(r.x, r.y);
      used++;
    }
    for (let i = used; i < G.pinPool.length; i++) G.pinPool[i].box.visible = false;
  };

  window.FlowGPU = G;
})();
