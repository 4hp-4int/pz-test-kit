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

// Tick the assembled program through representative states and collect every
// texture name the panel actually draws (item icons + the SSOChrome nine-patch
// pieces), so the browser render is dressed exactly like the harness one.
function collectTextureNames(program) {
  const fengari = require("fengari");
  const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  if (lauxlib.luaL_dostring(L, to_luastring(program)) !== lua.LUA_OK)
    throw new Error("assemble: " + to_jsstring(lua.lua_tostring(L, -1)));
  const tick = ev => {
    lua.lua_getglobal(L, to_luastring("UIView_tick"));
    lua.lua_pushstring(L, to_luastring(ev));
    if (lua.lua_pcall(L, 1, 1, 0) !== lua.LUA_OK)
      throw new Error("tick " + ev + ": " + to_jsstring(lua.lua_tostring(L, -1)));
    const s = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_pop(L, 1);
    return JSON.parse(s);
  };
  const names = new Set();
  const states = ["render", "text beer", "reset", "text eat", "reset",
    "key tab", "reset", "key down", "key down", "key enter", "reset",
    "text 5 open box", "reset", "text ?", "reset",
    "bleeding on", "bleeding off", "wounded on", "wounded off",
    "theme midnight", "theme paper", "theme forge", "theme cartRadio",
    "theme diner", "reset"];
  for (const ev of states) {
    for (const op of tick(ev).ops || [])
      if (op.op === "texture" && op.name) names.add(op.name);
  }
  return names;
}

function main() {
  const lua = assembleLua();

  // icons: union of a live-run texture sweep and the scene's declared Item_*
  // names, base64-inlined from the warmed cache
  const sceneSrc = fs.readFileSync(MODULES["UIView/scenes/SaucePalette"], "utf8")
    + fs.readFileSync(MODULES["UIView/scenes/PaletteStates"], "utf8");
  const names = new Set(sceneSrc.match(/Item_[A-Za-z0-9_]+/g) || []);
  for (const n of collectTextureNames(lua)) names.add(n);
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
  console.error(`[wasm-embed] ${Object.keys(icons).length}/${names.size} textures inlined, lua program ${Math.round(lua.length/1024)} KB`);
}
main();
