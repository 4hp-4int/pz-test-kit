--[[
    PZ Test Kit — Line coverage (source instrumentation)
    ====================================================
    Records which source LINES of the mod-under-test actually execute during a
    test run, with NO VM patch and NO debug hooks (PZ's Kahlua ships neither).

    HOW
    ---
    When the require resolver loads a module that's in coverage scope, it asks
    `_pz_cov_compile(source, name, path)` for a chunk. We:
      1. INSTRUMENT the source — inject a `__cov(id, line)` probe at the start of
         each statement-line (see the instrumentor's safety rules below);
      2. COMPILE-VERIFY — loadstring the instrumented source. If it fails, we
         return nil so the resolver loads the ORIGINAL, uninstrumented source.
         => instrumentation can NEVER break the mod under test; worst case a file
         just isn't covered (and is reported as a fallback).
      3. REGISTER each probed line as a coverage POINT (the denominator).
    At runtime each probe marks its line HIT (the numerator). The Java runner
    reads `_pz_coverage` after each test file and unions it across the suite.

    SCOPE
    -----
    `_pz_cov_scope` (set by --coverage=<substr>) limits instrumentation to
    modules whose require-name or file path contains the substring. Unset =
    every resolver module. Test files + kahlua harness + vanilla_requires don't
    go through the resolver, so they're never instrumented.

    GRANULARITY
    -----------
    Statement-line coverage: one probe per line, injected at the line's FIRST
    token, only when that position is unambiguously a new statement at block
    level (bracket depth 0, prior token not a continuation). Lines that are pure
    continuations / table-constructor interiors / block keywords (end/else/...)
    aren't probed — so they're not in the denominator either. Every counted line
    is one we can actually observe execute.
]]

_pz_coverage   = _pz_coverage   or {}   -- [path] = { name, file, points={[line]=true}, hit={[line]=true}, fallback }
_pz_cov_files  = _pz_cov_files  or {}   -- [id]   = entry  (id->entry for the runtime probe)
_pz_cov_nextId = _pz_cov_nextId or 0

-- Runtime probe. Kept tiny — it runs on every executed statement-line.
-- `_pz_cov_test` is set by the executor around each test under
-- --coverage-per-test: [id] = {[line]=true}, i.e. what THIS test executed.
function __cov(id, line)
    local e = _pz_cov_files[id]
    if e then
        e.hit[line] = true
        local t = _pz_cov_test
        if t then
            local s = t[id]
            if not s then s = {}; t[id] = s end
            s[line] = true
        end
    end
end

-- ── scope test ────────────────────────────────────────────────────────────
function _pz_cov_should(name, path)
    local scope = _pz_cov_scope
    if not scope or scope == "" then return true end
    if name and name:find(scope, 1, true) then return true end
    if path and tostring(path):find(scope, 1, true) then return true end
    return false
end

-- ── lexer helpers ───────────────────────────────────────────────────────────
local function isAlpha(b) return b == 95 or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) end       -- _ A-Z a-z
local function isAlnum(b) return isAlpha(b) or (b >= 48 and b <= 57) end                               -- + 0-9
local function isDigit(b) return b >= 48 and b <= 57 end
local function isWS(b)    return b == 32 or b == 9 or b == 13 end                                      -- space tab CR (LF handled separately)

-- A token text that, as the PRIOR significant token, means the statement is
-- unfinished — so the next line is a continuation, not a new statement.
local CONT = {
    ["+"]=true, ["-"]=true, ["*"]=true, ["/"]=true, ["%"]=true, ["^"]=true, ["#"]=true,
    [".."]=true, ["<"]=true, ["<="]=true, [">"]=true, [">="]=true, ["=="]=true, ["~="]=true,
    ["="]=true, ["("]=true, ["{"]=true, ["["]=true, [","]=true, ["."]=true, [":"]=true,
    ["and"]=true, ["or"]=true, ["not"]=true, ["return"]=true,
}
-- Keywords that ALWAYS begin a statement and can't be an expression continuation
-- (so they're safe to probe regardless of the prior token).
local STMT_KW = {
    ["local"]=true, ["if"]=true, ["while"]=true, ["for"]=true, ["repeat"]=true,
    ["return"]=true, ["break"]=true,
}
-- All Lua 5.1 keywords. A keyword at a line start is only a safe probe point when
-- it's a statement starter (STMT_KW) or `function`; every OTHER keyword (and / or /
-- not / then / else / end / in / nil / true / false / until / elseif / do) is part
-- of an enclosing expression or block and must NEVER be probed before — doing so was
-- the bug that broke multi-line `if a\n and b then` and `return x\n or y`.
local KEYWORD = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["if"]=true,
    ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
    ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true, ["until"]=true,
    ["while"]=true,
}

-- Match a long bracket `[`, `[=[`, ... at byte index i (1-based, s:byte). Returns
-- (level, contentStart) if i opens a long bracket, else nil.
local function longOpen(s, i)
    if s:byte(i) ~= 91 then return nil end          -- '['
    local j = i + 1
    while s:byte(j) == 61 do j = j + 1 end           -- '='
    if s:byte(j) == 91 then return (j - i - 1), j + 1 end
    return nil
end

-- Consume a long bracket body from contentStart at the given level; return
-- (indexAfterClose, newlineCount).
local function longConsume(s, contentStart, level)
    local close = "]" .. string.rep("=", level) .. "]"
    local a, b = s:find(close, contentStart, true)
    local stop = a and (b + 1) or (#s + 1)           -- malformed -> to EOF (won't compile -> fallback)
    local nl = 0
    local from = contentStart
    while true do
        local nlpos = s:find("\n", from, true)
        if not nlpos or nlpos >= stop then break end
        nl = nl + 1; from = nlpos + 1
    end
    return stop, nl
end

-- ── the instrumentor ────────────────────────────────────────────────────────
-- Walk the source once, copying it through while injecting `__cov(id,line); `
-- at each safe statement-line start. Fills entry.points. Returns the new source.
local function instrument(src, id, entry)
    local out, oi = {}, 0
    local function emit(str) oi = oi + 1; out[oi] = str end

    local n = #src
    local i = 1
    local line = 1
    local depth = 0           -- () {} [] nesting carried across lines
    local atLineStart = true  -- no significant token seen yet on this logical line
    local lastTok = nil       -- text of the previous significant token

    while i <= n do
        local b = src:byte(i)

        if b == 10 then                                  -- '\n'
            emit("\n"); i = i + 1; line = line + 1; atLineStart = true

        elseif isWS(b) then
            local j = i + 1
            while j <= n and isWS(src:byte(j)) do j = j + 1 end
            emit(src:sub(i, j - 1)); i = j

        elseif b == 45 and src:byte(i + 1) == 45 then    -- '--' comment (not a significant token)
            local lvl, cstart = longOpen(src, i + 2)
            if lvl then
                local stop, nl = longConsume(src, cstart, lvl)
                emit(src:sub(i, stop - 1)); i = stop; line = line + nl
            else
                local j = i
                while j <= n and src:byte(j) ~= 10 do j = j + 1 end
                emit(src:sub(i, j - 1)); i = j
            end

        else
            -- A SIGNIFICANT token begins here. If it's the first on the line,
            -- decide whether to inject a probe BEFORE emitting it.
            local lvl, cstart = longOpen(src, i)         -- long string?
            if lvl then
                atLineStart = false
                local stop, nl = longConsume(src, cstart, lvl)
                emit(src:sub(i, stop - 1)); i = stop; line = line + nl
                lastTok = "<str>"
            elseif b == 34 or b == 39 then               -- short string " or '
                if atLineStart then atLineStart = false end   -- a string never starts a probe-worthy stmt
                local q = b; local j = i + 1
                while j <= n do
                    local c = src:byte(j)
                    if c == 92 then j = j + 2                  -- backslash escape
                    elseif c == q or c == 10 then break
                    else j = j + 1 end
                end
                if src:byte(j) == q then j = j + 1 end
                emit(src:sub(i, j - 1)); i = j; lastTok = "<str>"

            elseif isAlpha(b) then                       -- identifier / keyword
                local j = i + 1
                while j <= n and isAlnum(src:byte(j)) do j = j + 1 end
                local tok = src:sub(i, j - 1)
                if atLineStart then
                    local inject
                    if STMT_KW[tok] then inject = true                         -- local/if/while/for/repeat/return/break
                    elseif tok == "function" then inject = not (lastTok and CONT[lastTok])
                    elseif KEYWORD[tok] then inject = false                    -- and/or/not/then/else/end/in/nil/...
                    else inject = not (lastTok and CONT[lastTok])             -- a real Name: assignment / call
                    end
                    if inject and depth == 0 then
                        emit("__cov(" .. id .. "," .. line .. "); ")
                        entry.points[line] = true
                    end
                    atLineStart = false
                end
                emit(tok); i = j; lastTok = tok

            elseif isDigit(b) or (b == 46 and isDigit(src:byte(i + 1) or 0)) then  -- number
                local j = i
                -- consume a numeric run (digits, ., hex, exponent signs) — coarse but fine
                while j <= n do
                    local c = src:byte(j)
                    if isAlnum(c) or c == 46 then j = j + 1
                    elseif (c == 43 or c == 45) and (src:byte(j - 1) == 101 or src:byte(j - 1) == 69) then j = j + 1  -- e+ E-
                    else break end
                end
                if atLineStart then atLineStart = false end   -- a number never starts a stmt
                emit(src:sub(i, j - 1)); i = j; lastTok = "<num>"

            else                                         -- operator / punctuation
                local two = src:sub(i, i + 1)
                local tok
                if two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">=" or two == "::" then
                    tok = two
                else
                    tok = string.char(b)
                end
                if atLineStart then atLineStart = false end   -- punct never starts a probe
                if tok == "(" or tok == "{" or tok == "[" then depth = depth + 1
                elseif tok == ")" or tok == "}" or tok == "]" then if depth > 0 then depth = depth - 1 end end
                emit(tok); i = i + #tok; lastTok = tok
            end
        end
    end

    return table.concat(out)
end

-- ── resolver entry point ────────────────────────────────────────────────────
-- Instrument + compile-verify + register. Returns a compiled chunk, or nil to
-- tell the resolver to fall back to the original source.
function _pz_cov_compile(source, name, path)
    local key = tostring(path or name)
    local entry = _pz_coverage[key]
    if not entry then
        _pz_cov_nextId = _pz_cov_nextId + 1
        entry = { name = name, file = key, id = _pz_cov_nextId, points = {}, hit = {} }
        _pz_coverage[key] = entry
        _pz_cov_files[entry.id] = entry
    else
        entry.points = {}   -- re-instrumenting in a fresh env: rebuild points
    end

    local ok, inst = pcall(instrument, source, entry.id, entry)
    if not ok then
        entry.fallback = true; entry.points = {}
        print("[coverage] instrument error in " .. tostring(name) .. ": " .. tostring(inst))
        return nil
    end
    local chunk, cerr = _pz_compile(inst, key)
    if not chunk then
        entry.fallback = true; entry.points = {}
        print("[coverage] instrumented source failed to compile (" .. tostring(name) ..
              "), using original: " .. tostring(cerr))
        return nil
    end
    entry.fallback = nil
    return chunk
end

return true
