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

  // PZ's DrawTextureScaled multiplies texture pixels by the call's rgb —
  // chrome packs bake strokes near-white and rely on that tint (one texture,
  // any ink). Mirror it here or tinted assets preview as white. Multiply the
  // image by the rgb color, then restore the image's own alpha.
  var tintCache = typeof WeakMap !== "undefined" ? new WeakMap() : null;
  function tintedImage(img, r, g, b) {
    var key = r.toFixed(3) + "," + g.toFixed(3) + "," + b.toFixed(3);
    var perImg = tintCache && tintCache.get(img);
    if (perImg && perImg[key]) return perImg[key];
    var c = document.createElement("canvas");
    c.width = img.width || 1; c.height = img.height || 1;
    var cx = c.getContext("2d");
    cx.drawImage(img, 0, 0);
    cx.globalCompositeOperation = "multiply";
    cx.fillStyle = "rgb(" + Math.round(r * 255) + "," + Math.round(g * 255) + "," + Math.round(b * 255) + ")";
    cx.fillRect(0, 0, c.width, c.height);
    cx.globalCompositeOperation = "destination-in";
    cx.drawImage(img, 0, 0);
    if (tintCache) {
      if (!perImg) { perImg = {}; tintCache.set(img, perImg); }
      perImg[key] = c;
    }
    return c;
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
        case "text": {
          ctx.fillStyle = css(op.r, op.g, op.b, op.a);
          // Prefer the line height PZ actually reports for this font at the
          // modelled size; the FONTPX table is a fallback for older frames.
          // ~0.75 em per line box is the usual bitmap-font ratio, and getting
          // this right is what keeps the letter-spacing correction small.
          var px = op.fh ? Math.max(6, Math.round(op.fh * 0.75)) : fontPx(op.font);
          ctx.font = px + "px ui-monospace,Consolas,monospace";
          // PZ's drawText y is the TOP of the line box; canvas fillText
          // defaults to the alphabetic BASELINE. Without this every string in
          // every preview sits roughly a line lower than the game draws it --
          // invisible in a page of pure text, and wrong the moment anything is
          // positioned against a glyph (a strike-through rendered as an
          // underline, which is a link affordance, on the memorial page).
          // Vertical placement, PZ-exact when the frame carries a baseline:
          // draw on the ALPHABETIC baseline at y + fb, which is where PZ's
          // bitmap font puts it. Falling back to "top" lines the glyph box up
          // with the browser font's own ascent instead, which sits the letters
          // higher in the line and drops anything positioned against them --
          // the memorial's strike-through landed under the word.
          var fb = op.fb;
          ctx.textBaseline = fb ? "alphabetic" : "top";
          ctx.textAlign = op.align === "centre" ? "center"
            : (op.align === "right" ? "right" : "left");
          // op.mw is the width PZ's own font metrics gave this string, which is
          // what the layout was computed against. The canvas draws a different
          // typeface, so close the difference with LETTER SPACING rather than a
          // horizontal scale: scaling stretches the letterforms themselves and
          // the whole preview reads as squashed or smeared, which is its own
          // kind of lie. Spacing keeps every glyph its true shape and still
          // lands the string on the width the layout reserved for it.
          var hasSpacing = ("letterSpacing" in ctx);
          if (op.mw && hasSpacing) {
            ctx.letterSpacing = "0px";
            var natural = ctx.measureText(op.str).width;
            var n = op.str.length;
            if (n > 0 && natural > 0) {
              ctx.letterSpacing = ((op.mw - natural) / n).toFixed(3) + "px";
            }
          }
          ctx.fillText(op.str, op.x, op.y + (fb || 0));
          if (hasSpacing) ctx.letterSpacing = "0px";
          ctx.textAlign = "left";
          break;
        }
        case "texture": {
          // NIL-texture draw (name ""): the engine's DrawTextureScaledColor
          // with a null texture paints a SOLID colour quad (how TooltipLib's
          // accent line and SIR's ledger dot-leaders/rules draw). A hatched
          // placeholder here misreads as a missing asset — render the truth.
          if (!op.name) {
            ctx.fillStyle = css(op.r, op.g, op.b, op.a);
            ctx.fillRect(op.x, op.y, op.w || 0, op.h || 0);
            break;
          }
          var img = images && images.get(op.name);
          var w = op.w || 32, h = op.h || 32;
          if (img) {
            ctx.globalAlpha = op.a == null ? 1 : op.a;
            var needsTint = (op.r != null && op.r < 0.995)
              || (op.g != null && op.g < 0.995)
              || (op.b != null && op.b < 0.995);
            ctx.drawImage(needsTint ? tintedImage(img, op.r, op.g, op.b) : img,
              op.x, op.y, w, h);
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
