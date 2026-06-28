// Run the assembled Lua program in Fengari (Node) and exercise UIView_tick.
// This validates the real pal_ui.lua survives Lua 5.3 before we ship it to a
// browser. Prints a short summary of each tick's frame.
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const { assembleLua } = require("./assemble");

const program = assembleLua();

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function die(where) {
  console.error(`[fengari] ${where}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
  process.exit(1);
}

if (lauxlib.luaL_dostring(L, to_luastring(program)) !== lua.LUA_OK) die("load program");

function tick(ev) {
  lua.lua_getglobal(L, to_luastring("UIView_tick"));
  lua.lua_pushstring(L, to_luastring(ev));
  if (lua.lua_pcall(L, 1, 1, 0) !== lua.LUA_OK) die(`tick(${ev})`);
  const out = to_jsstring(lua.lua_tostring(L, -1));
  lua.lua_pop(L, 1);
  return out;
}

function summary(json, label) {
  let f;
  try { f = JSON.parse(json); } catch (e) { return `${label}: BAD JSON (${json.slice(0,80)})`; }
  const texts = (f.ops || []).filter(o => o.op === "text").map(o => o.str);
  const ops = (f.ops || []).length;
  return `${label}: ${ops} ops, ${f.width}x${f.height} | ${texts.slice(0, 6).join(" / ")}`;
}

console.log(summary(tick("render"), "render"));
console.log(summary(tick("text water"), "text 'water'"));
console.log(summary(tick("reset"), "reset"));
console.log(summary(tick("key tab"), "key tab (browse)"));
console.log(summary(tick("reset"), "reset"));
console.log(summary(tick("click 400 250"), "click equip group"));
console.log("[fengari] OK — pal_ui runs under Lua 5.3");
