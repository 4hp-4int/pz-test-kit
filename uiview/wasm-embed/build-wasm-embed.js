#!/usr/bin/env node
/*
 * Build the client-side, Lua-on-WASM SaucePalette embed: the real pal_ui.lua
 * runs in Fengari in the reader's browser, free-form interactive, no backend.
 * Writes embed.html + fengari-web.js + replay.js into the blog post bundle.
 *
 *   node build-wasm-embed.js [outDir]
 */
const fs = require("fs");
const path = require("path");
const { assembleLua, MODULES } = require("./assemble");

const HERE = __dirname;
const UIVIEW = path.resolve(HERE, "..");
const OUT_DIR = process.argv[2] ||
  "C:/Users/Khalen/Code/4hp-4int/src/content/posts/headless-pz-ui-harness";

function b64(file) { return "data:image/png;base64," + fs.readFileSync(file).toString("base64"); }

function main() {
  const lua = assembleLua();

  // icons referenced by the palette scene -> base64 from the warmed cache
  const sceneSrc = fs.readFileSync(MODULES["UIView/scenes/SaucePalette"], "utf8");
  const names = [...new Set((sceneSrc.match(/Item_[A-Za-z0-9_]+/g) || []))];
  const icons = {};
  for (const n of names) {
    const f = path.join(UIVIEW, ".iconcache", n + ".png");
    if (fs.existsSync(f)) icons[n] = b64(f);
  }

  const tpl = fs.readFileSync(path.join(HERE, "wasm.template.html"), "utf8");
  const html = tpl
    .split("/*__LUA__*/").join(lua)
    .split("/*__ICONS__*/{}").join(JSON.stringify(icons));

  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, "embed.html"), html);
  // VM + draw core as sibling assets the bundle serves
  fs.copyFileSync(
    path.resolve(HERE, "node_modules", "fengari-web", "dist", "fengari-web.js"),
    path.join(OUT_DIR, "fengari-web.js"));
  fs.copyFileSync(path.join(UIVIEW, "replay.js"), path.join(OUT_DIR, "replay.js"));

  const kb = Math.round(html.length / 1024);
  console.error(`[wasm-embed] wrote embed.html (${kb} KB) + fengari-web.js + replay.js`);
  console.error(`[wasm-embed] ${names.length} icons, lua program ${Math.round(lua.length/1024)} KB`);
}
main();
