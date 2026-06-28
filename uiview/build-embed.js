#!/usr/bin/env node
/*
 * Build a self-contained interactive SaucePalette widget for the blog.
 * Drives the running live-drive bridge through the interaction space, captures
 * each real harness frame, base64-inlines the referenced PZ icons + replay.js,
 * and emits a single embed.html the reader can actually type into / browse.
 *
 *   node build-embed.js [bridgePort] [outFile]
 * Requires the bridge running:  node serve-bridge.js SaucePalette 8753
 */
const fs = require("fs");
const path = require("path");

const PORT = process.argv[2] || "8753";
const OUT = process.argv[3] ||
  "C:/Users/Khalen/Code/4hp-4int/src/content/posts/headless-pz-ui-harness/embed.html";
const HERE = __dirname;
const BASE = `http://localhost:${PORT}`;

async function ev(cmd) {
  const r = await fetch(BASE + "/event", { method: "POST", body: cmd });
  return r.json();
}
// run a sequence (reset + inputs); return the final frame
async function capture(seq) {
  let frame = null;
  for (const c of seq) frame = await ev(c);
  return frame;
}

async function main() {
  const words = ["water", "bandage", "build", "eat", "read", "generator", "open", "smoke"];
  const queries = new Set([""]);
  for (const w of words) for (let i = 1; i <= w.length; i++) queries.add(w.slice(0, i));

  const frames = {};
  console.error("[embed] capturing zero + selection states...");
  frames["q:"] = await capture(["reset"]);
  for (let i = 1; i <= 10; i++) {
    frames["sel:" + i] = await capture(["reset", ...Array(i).fill("key down")]);
  }
  console.error(`[embed] capturing ${queries.size} query states...`);
  for (const q of queries) {
    if (q === "") continue;
    frames["q:" + q] = await capture(["reset", "text " + q]);
  }
  frames["browse"] = await capture(["reset", "key tab"]);
  frames["expand"] = await capture(["reset", "click 400 250"]);
  frames["nomatch"] = await capture(["reset", "text zqxwk"]);
  await ev("reset");

  // collect referenced icon names -> base64 from the warmed .iconcache
  const iconNames = new Set();
  for (const k in frames) {
    for (const op of (frames[k].ops || [])) {
      if (op.op === "texture" && op.name) iconNames.add(op.name);
    }
  }
  const icons = {};
  for (const name of iconNames) {
    const f = path.join(HERE, ".iconcache", name.replace(/[^A-Za-z0-9_]/g, "") + ".png");
    if (fs.existsSync(f)) icons[name] = "data:image/png;base64," + fs.readFileSync(f).toString("base64");
  }
  console.error(`[embed] ${Object.keys(frames).length} frames, ${Object.keys(icons).length} icons inlined`);

  const replay = fs.readFileSync(path.join(HERE, "replay.js"), "utf8");
  const tpl = fs.readFileSync(path.join(HERE, "embed.template.html"), "utf8");
  // split/join (not replace) so $ in content isn't treated as a replacement
  // pattern; consume the trailing {} default so the assignment stays valid.
  const html = tpl
    .split("/*__REPLAY__*/").join(replay)
    .split("/*__FRAMES__*/{}").join(JSON.stringify(frames))
    .split("/*__ICONS__*/{}").join(JSON.stringify(icons));
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, html);
  console.error("[embed] wrote " + OUT + "  (" + Math.round(html.length / 1024) + " KB)");
}
main().catch(e => { console.error(e); process.exit(1); });
