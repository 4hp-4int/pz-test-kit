// Assemble the self-contained Lua program: browser harness globals + a require
// shim with every module inlined as a long-bracket string + the boot driver.
// Shared by the Node test and the browser-embed builder.
const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const UIVIEW = path.resolve(HERE, "..", "media", "lua", "client", "UIView");
const SIR = "C:/Users/Khalen/Code/pz-mods/sauce-invrender/media/lua/client/palette";

const MODULES = {
  "UIView/Recorder": path.join(UIVIEW, "Recorder.lua"),
  "UIView/UIMock": path.join(UIVIEW, "UIMock.lua"),
  "UIView/Render": path.join(UIVIEW, "Render.lua"),
  "UIView/Input": path.join(UIVIEW, "Input.lua"),
  "UIView/scenes/SaucePalette": path.join(UIVIEW, "scenes", "SaucePalette.lua"),
  "palette/pal_ui": path.join(SIR, "pal_ui.lua"),
};

function longBracket(src) {
  // pick an = level that doesn't collide with the source
  for (let n = 4; n < 12; n++) {
    const close = "]" + "=".repeat(n) + "]";
    if (!src.includes(close)) return { open: "[" + "=".repeat(n) + "[", close };
  }
  throw new Error("no safe long-bracket level");
}

function assembleLua() {
  const harness = fs.readFileSync(path.join(HERE, "browser-harness.lua"), "utf8");
  const boot = fs.readFileSync(path.join(HERE, "browser-boot.lua"), "utf8");

  let shim = `
local _src = {}
local _loaded = {}
local _NIL = {}
function require(name)
  name = tostring(name):gsub("\\\\","/"):gsub("%.lua$","")
  local c = _loaded[name]
  if c ~= nil then if c == _NIL then return nil end return c end
  local s = _src[name]
  if not s then _loaded[name] = _NIL; return nil end
  local chunk, e = load(s, "@"..name)
  if not chunk then error("compile "..name..": "..tostring(e)) end
  _loaded[name] = _NIL
  local r = chunk()
  _loaded[name] = (r ~= nil) and r or _NIL
  return r
end
`;

  let srcAssign = "";
  for (const [name, file] of Object.entries(MODULES)) {
    const body = fs.readFileSync(file, "utf8");
    const { open, close } = longBracket(body);
    // leading newline inside long bracket is stripped by Lua, which is fine
    srcAssign += `_src[${JSON.stringify(name)}] = ${open}\n${body}\n${close}\n`;
  }

  return [harness, shim, srcAssign, boot].join("\n");
}

module.exports = { assembleLua, MODULES };
