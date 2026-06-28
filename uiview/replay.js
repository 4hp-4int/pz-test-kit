/*
  UIView — Replay core (canonical, shared)
  ========================================
  The single source of truth for turning a recorded display list (see
  Recorder.lua) into pixels on a 2D canvas. viewer.html, player.html and
  gallery.html all use THIS file — they inline it at build time via the
  /*__REPLAY__*/ /* token (keeps each shell self-contained: no server, no CORS,
  works under file:// and under Playwright set_content with no base URL).

  Do not fork this logic into a shell. If a shell needs more, extend the API
  here so every shell benefits (icons, clipping, fonts all live here).

  Public API (window.UIViewReplay):
    fontPx(font)                       -> px size for a UIMock font name
    css(r,g,b,a)                       -> rgba() string (0..1 floats)
    collectTextureNames(frames)        -> [assetPath, ...] referenced by ops
    preload(frames, opts)              -> Promise<Map name->Image|null>
        opts.assetMap : { name: dataURI }  (build-time base64 — preferred)
        opts.roots    : [urlPrefix, ...]   (live-dev fallback fetch)
    drawFrame(ctx, frame, opts)        -> paint one frame's ops
        opts.images   : Map name->Image (from preload)
        opts.outlines : bool  (dashed element-tree boxes)
        opts.opIds    : bool  (paint z ids)

  Op shapes are produced by Recorder.lua. Clip/unclip are handled here so the
  gap track's stencil work (G2) rides this core without touching the shells.
*/
(function (global) {
  "use strict";

  // font name -> px (tracks UIMock FONT heights, minus a hair for baseline)
  var FONTPX = {
    Small: 12, Medium: 15, Large: 20, Massive: 30, NewSmall: 12, NewMedium: 15,
    NewLarge: 20, MediumNew: 15, Title: 24, Cred1: 17, Code: 12
  };
  function fontPx(f) { return FONTPX[f] || 12; }

  function css(r, g, b, a) {
    return "rgba(" + Math.round((r == null ? 1 : r) * 255) + "," +
      Math.round((g == null ? 1 : g) * 255) + "," +
      Math.round((b == null ? 1 : b) * 255) + "," +
      (a == null ? 1 : a) + ")";
  }

  // A texture op whose name ends in an image extension is a real asset we can
  // resolve to pixels; everything else (item icons, generated ids) stays a box.
  function isAssetPath(name) {
    return typeof name === "string" && /\.(png|jpe?g)$/i.test(name);
  }

  function frameList(frames) {
    if (!frames) return [];
    if (Array.isArray(frames)) return frames;
    if (frames.frames) return frames.frames.map(function (b) { return b.frame || b; });
    return [frames];
  }

  // Every texture-op name (file paths AND bare PZ subtexture names like
  // "Item_Bandage"). Resolution happens in preload(): an assetMap entry wins,
  // else a path-looking name is fetched from roots, else it stays a placeholder.
  function collectTextureNames(frames) {
    var seen = {}, out = [];
    frameList(frames).forEach(function (fr) {
      (fr.ops || []).forEach(function (op) {
        if (op.op === "texture" && op.name && !seen[op.name]) {
          seen[op.name] = 1; out.push(op.name);
        }
      });
    });
    return out;
  }

  function loadImage(src) {
    return new Promise(function (res) {
      if (!src) return res(null);
      var im = new Image();
      im.onload = function () { res(im); };
      im.onerror = function () { res(null); };
      im.src = src;
    });
  }

  // Try each candidate URL in turn (live-dev fallback when no assetMap given).
  function loadFirst(urls) {
    return urls.reduce(function (p, url) {
      return p.then(function (got) { return got || loadImage(url); });
    }, Promise.resolve(null));
  }

  function preload(frames, opts) {
    opts = opts || {};
    var names = collectTextureNames(frames);
    var assetMap = opts.assetMap || {};
    var roots = opts.roots || [];
    var cache = new Map();
    var tasks = names.map(function (name) {
      var src = assetMap[name];
      var p = src ? loadImage(src)
        : (isAssetPath(name)
            ? loadFirst(roots.map(function (r) { return r.replace(/\/$/, "") + "/" + name; }))
            : Promise.resolve(null));
      return p.then(function (img) { cache.set(name, img); });
    });
    return Promise.all(tasks).then(function () { return cache; });
  }

  function drawFrame(ctx, frame, opts) {
    opts = opts || {};
    var images = opts.images;
    var ops = frame.ops || [];
    // PZ's drawText uses a TOP-LEFT origin (y = top of the glyph box). Own this
    // here so every shell renders identically — a shell that forgets to set it
    // would draw all text ~a line too high (alphabetic baseline).
    ctx.textBaseline = "top";
    for (var i = 0; i < ops.length; i++) {
      var op = ops[i];
      switch (op.op) {
        case "clip":            // G2 stencil push
          ctx.save();
          ctx.beginPath();
          ctx.rect(op.x, op.y, op.w, op.h);
          ctx.clip();
          break;
        case "unclip":          // G2 stencil pop
          ctx.restore();
          break;
        case "rect":
          ctx.fillStyle = css(op.r, op.g, op.b, op.a);
          ctx.fillRect(op.x, op.y, op.w, op.h);
          break;
        case "rectborder":
          ctx.strokeStyle = css(op.r, op.g, op.b, op.a);
          ctx.lineWidth = 1;
          ctx.strokeRect(op.x + 0.5, op.y + 0.5, op.w - 1, op.h - 1);
          break;
        case "text":
          ctx.fillStyle = css(op.r, op.g, op.b, op.a);
          ctx.font = fontPx(op.font) + "px ui-monospace,Consolas,monospace";
          ctx.textAlign = op.align === "centre" ? "center"
            : (op.align === "right" ? "right" : "left");
          ctx.fillText(op.str, op.x, op.y);
          ctx.textAlign = "left";
          break;
        case "texture": {
          var img = images && images.get(op.name);
          var w = op.w || 32, h = op.h || 32;
          if (img) {
            ctx.globalAlpha = op.a == null ? 1 : op.a;
            // tint is rarely meaningful for icon previews; draw straight pixels.
            ctx.drawImage(img, op.x, op.y, w, h);
            ctx.globalAlpha = 1;
          } else {
            placeholderBox(ctx, op.x, op.y, w, h);
          }
          break;
        }
        case "itemicon":
          placeholderBox(ctx, op.x, op.y, op.w || 32, op.h || 32);
          break;
      }
    }
    if (opts.outlines && frame.tree) outlineTree(ctx, frame.tree);
    if (opts.opIds) {
      ctx.fillStyle = "#ff0";
      ctx.font = "8px monospace";
      for (var j = 0; j < ops.length; j++) ctx.fillText(ops[j].z, ops[j].x, ops[j].y - 1);
    }
  }

  // A faint slot for textures we couldn't resolve / item icons (no file). No
  // path text — that was the old smear under row labels.
  function placeholderBox(ctx, x, y, w, h) {
    ctx.fillStyle = "rgba(120,90,180,0.16)";
    ctx.fillRect(x, y, w, h);
    ctx.strokeStyle = "rgba(155,109,214,0.5)";
    ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    ctx.strokeStyle = "rgba(155,109,214,0.35)";
    ctx.beginPath();
    ctx.moveTo(x + 3, y + h - 3); ctx.lineTo(x + w - 3, y + 3); ctx.stroke();
  }

  function outlineTree(ctx, node) {
    if (!node) return;
    ctx.strokeStyle = "rgba(255,90,160,0.55)";
    ctx.setLineDash([3, 2]); ctx.lineWidth = 1;
    ctx.strokeRect(node.x + 0.5, node.y + 0.5, node.w - 1, node.h - 1);
    ctx.setLineDash([]);
    var kids = Array.isArray(node.children) ? node.children : [];
    for (var i = 0; i < kids.length; i++) outlineTree(ctx, kids[i]);
  }

  global.UIViewReplay = {
    FONTPX: FONTPX,
    fontPx: fontPx,
    css: css,
    isAssetPath: isAssetPath,
    collectTextureNames: collectTextureNames,
    preload: preload,
    drawFrame: drawFrame
  };
})(this);
