--[[
    PZ Test Kit — Translator
    ========================
    A faithful stand-in for zombie.core.Translator's getText path, so tests see
    what the game sees instead of an identity function.

    Why this exists: since 42.20.1 `Translator.getText` runs EVERY string
    through Java's `String.formatted()`, and the JSON loader has already
    rewritten the file's "%1" into the format specifier "%1$s". A mod that
    fetches with `getText(key)` and substitutes the placeholder itself
    therefore leaves the specifier unfed. Translator catches the
    MissingFormatArgumentException and hands the text back intact, so the line
    still RENDERS — the only symptom is a WARN in the debug log, once per call.
    An identity-function mock cannot show you that; this can.

    Modelled from the decompiled 42.20.1 source:

      FORMAT_TOKEN = Pattern.compile("%%|%([1-9])")
      formatFixer  = replace "%N" -> "%N$s", leave "%%" alone   [load time]
      fixupArgs    = null -> "", Double -> String (ALWAYS, integral or not)
      getText(desc, args...) {
          try { return text.formatted(fixupArgs(args)) }
          catch (MissingFormatArgumentException) { WARN; return text }
          catch (IllegalFormatException) {
              WARN
              try { return text.replaceAll("%(?=[^ds.]|$)", "%%")
                               .replaceAll("%%(\\d+)", "%$1\\$s").formatted(args) }
              catch (IllegalFormatException) { return text }
          }
      }

    The fixupArgs detail is load-bearing and easy to miss: every Lua number
    reaches Java as a Double and comes out of fixupArgs as a STRING. So "%d"
    in a translation is never satisfiable from Lua — it throws
    IllegalFormatConversionException every time. Tests see that here.

    STRINGS
    -------
    Populated from the mod's own bundle when `translate = "EN"` is set in
    pz-test.lua (the runner parses media/lua/shared/Translate/<lang>/*.json).
    Without it the table is empty and getText echoes the key, exactly as the
    older mock did — the format semantics still apply, which is a no-op for a
    key with no placeholders in it.

    TEST API
    --------
        PZTestKit.Translate.set(key, value)      -- add/override one string
        PZTestKit.Translate.load({ k = v, ... })  -- add/override many
        PZTestKit.Translate.reset()               -- clear the warning log
        PZTestKit.Translate.warnings()            -- { {key=, kind=, message=} }
        PZTestKit.Translate.capture(fn)           -- run fn, return its warnings
]]

_pz_translations = _pz_translations or {}

PZTestKit = PZTestKit or {}

local Translate = {}
PZTestKit.Translate = Translate

local strings  = _pz_translations
local warnings = {}
local reported = {}   -- key -> true, so a hot path prints once but records all

-- ── formatFixer (load-time pass) ────────────────────────────────────────────
-- FORMAT_TOKEN = "%%|%([1-9])" scanned left to right: "%%" is consumed as-is,
-- so "%%1" stays "%%1" and does NOT become a specifier. A single left-to-right
-- walk is the only way to reproduce that; two gsub passes get it wrong.
local function formatFixer(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "%" then
            local nxt = s:sub(i + 1, i + 1)
            if nxt == "%" then
                out[#out + 1] = "%%"
                i = i + 2
            elseif nxt ~= "" and nxt:match("[1-9]") then
                out[#out + 1] = "%" .. nxt .. "$s"
                i = i + 2
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function fixup(s)
    -- The loader also collapses <br> to a newline before anything else sees it.
    s = s:gsub("<br>", "\n"):gsub("<BR>", "\n")
    return formatFixer(s)
end

for k, v in pairs(strings) do strings[k] = fixup(v) end

-- ── fixupArgs ───────────────────────────────────────────────────────────────
-- nil -> "", every number -> its string form. Both Double branches in the Java
-- return a String, which is why "%d" can never be satisfied from Lua.
local function fixupArgs(...)
    local n = select("#", ...)
    local a = {}
    for i = 1, n do
        local v = select(i, ...)
        if v == nil then
            a[i] = ""
        elseif type(v) == "number" then
            a[i] = (v == math.floor(v)) and tostring(math.floor(v)) or tostring(v)
        else
            a[i] = v
        end
    end
    return a, n
end

-- Conversions that accept a String argument. Everything else (d, f, x, o, e...)
-- throws IllegalFormatConversionException once fixupArgs has stringified.
local STRING_CONV = { s = true, S = true, b = true, B = true, h = true, H = true }
local KNOWN_CONV  = {}
for c in ("bBhHsScCdoxXeEfgGaAtTn"):gmatch(".") do KNOWN_CONV[c] = true end

--- Java's Formatter over `text`, left to right.
--- @return string formatted, string|nil err  -- err is "missing" or "illegal"
local function javaFormat(text, a, argc)
    local out, i, n, auto = {}, 1, #text, 0
    while i <= n do
        local c = text:sub(i, i)
        if c ~= "%" then
            out[#out + 1] = c
            i = i + 1
        else
            local rest = text:sub(i + 1)
            if rest:sub(1, 1) == "%" then
                out[#out + 1] = "%"
                i = i + 2
            else
                -- %[index$][flags][width][.precision]conversion
                local idx, tail = rest:match("^(%d+)%$(.*)$")
                local body = tail or rest
                local spec = body:match("^[-#+ 0,(]*%d*%.?%d*")
                local conv = body:sub(#spec + 1, #spec + 1)
                if conv == "" or not KNOWN_CONV[conv] then
                    return text, "illegal"          -- UnknownFormatConversionException
                end
                local slot
                if idx then
                    slot = tonumber(idx)
                else
                    auto = auto + 1
                    slot = auto
                end
                if slot > argc then
                    return text, "missing"          -- MissingFormatArgumentException
                end
                local v = a[slot]
                if type(v) == "string" and not STRING_CONV[conv] then
                    return text, "illegal"          -- IllegalFormatConversionException
                end
                out[#out + 1] = tostring(v)
                i = i + 1 + (idx and (#idx + 1) or 0) + #spec + 1
            end
        end
    end
    return table.concat(out), nil
end

--- The 42.20.1 recovery pass: escape every "%" that is not the start of a
--- %d / %s / %.Nf, then turn the "%%N" that produces back into "%N$s".
local function recoverySquash(text)
    local out, i, n = {}, 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == "%" then
            local nxt = text:sub(i + 1, i + 1)
            out[#out + 1] = (nxt == "d" or nxt == "s" or nxt == ".") and "%" or "%%"
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return (table.concat(out):gsub("%%%%(%d+)", "%%%1$s"))
end

local capturing = 0

local function warn(key, kind, message)
    warnings[#warnings + 1] = { key = key, kind = kind, message = message }
    -- Print the first sighting of each key so unnoticed spam surfaces, but stay
    -- quiet inside capture() — there the caller is asking for these on purpose.
    if capturing == 0 and not reported[key] then
        reported[key] = true
        print("[PZTestKit][WARN] " .. message .. "  (further occurrences recorded, not printed)")
    end
end

local function render(desc, text, ...)
    local a, argc = fixupArgs(...)
    local out, err = javaFormat(text, a, argc)
    if err == "missing" then
        warn(desc, "missing", 'ERROR: Missing arguments for "' .. tostring(desc) .. '"')
        return text
    elseif err then
        warn(desc, "formatting", 'ERROR: Formatting "' .. tostring(desc) .. '"')
        local retry, err2 = javaFormat(recoverySquash(text), a, argc)
        if err2 then return text end
        return retry
    end
    return out
end

-- ── Public PZ globals ───────────────────────────────────────────────────────
function getText(key, ...)
    if key == nil then return "" end
    local text = strings[key]
    if text == nil then text = tostring(key) end   -- Translator returns the desc
    return render(key, text, ...)
end

function getTextOrNull(key, ...)
    if key == nil then return nil end
    local text = strings[key]
    if text == nil then return nil end
    return render(key, text, ...)
end

-- ── Test API ────────────────────────────────────────────────────────────────

--- Add or override one string. Runs the same load-time fixer the game does, so
--- pass the raw "%1" form exactly as it appears in the .json.
function Translate.set(key, value)
    strings[key] = fixup(value)
end

function Translate.load(t)
    for k, v in pairs(t) do strings[k] = fixup(v) end
end

function Translate.get(key)
    return strings[key]
end

function Translate.count()
    local n = 0
    for _ in pairs(strings) do n = n + 1 end
    return n
end

function Translate.reset()
    warnings = {}
    reported = {}
end

--- Every WARN recorded since the last reset, in order.
function Translate.warnings()
    local copy = {}
    for i, w in ipairs(warnings) do copy[i] = w end
    return copy
end

--- Run `fn`, return the WARNs it produced. Restores the previous log, so it
--- nests and does not disturb a surrounding capture.
function Translate.capture(fn)
    local saved, savedReported = warnings, reported
    warnings, reported = {}, {}
    capturing = capturing + 1
    local ok, err = pcall(fn)
    capturing = capturing - 1
    local got = warnings
    warnings, reported = saved, savedReported
    if not ok then error(err, 0) end
    return got
end

if _pz_translate_lang then
    print("[PZTestKit] Translator active (" .. _pz_translate_lang .. ", "
        .. Translate.count() .. " strings)")
end
