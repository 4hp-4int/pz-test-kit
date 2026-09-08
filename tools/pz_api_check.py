"""pz_api_check — does this Lua actually call methods Project Zomboid exposes?

WHY THIS EXISTS. On 2026-09-08 a live pass on vps-story found six bugs in two
hours that 104 green offline tests had never seen. Not one was a mock-fidelity
problem -- the files involved (WorldControl.lua, GameAdapter.lua) had NO tests
at all, so no mock was ever consulted. Every bug was the same shape: Lua called
a Java method or read a Java field that does not exist on PZ's Lua surface, and
because the call sat inside a pcall it failed SILENTLY and reported success.

  props:Is("streetlight")        -- invented; PropertyContainer has has(String)
  src.hydroPowered = false       -- public Java field; Kahlua ignores the write
  obj.streetLight                -- public Java field; reads nil, forever
  map:keySet():iterator()        -- iterator() is not exposed; scan was dead code
  RemoveChannel(chan)            -- takes an int frequency, not a channel

A test cannot catch these without being written first. A static check catches
them in a file nobody has tested, which is where they live.

HOW IT KNOWS. pz-dev-tools/indexes/java-api/*.txt: 822 classes, 17196
@UsedFromLua methods WITH RETURN TYPES, and -- the part that makes the field
bugs catchable -- 1213 public fields listed separately. Return types are what
let it chain: IsoObject.getProperties() -> PropertyContainer, so it knows what
`props` is two lines later.

PRECISION IS THE WHOLE PRODUCT. A checker that cries wolf gets switched off, so
this only ever speaks about a receiver whose class it is CERTAIN of: seeded from
a curated global map (getWorld() -> IsoWorld), extended by return types, and
DROPPED the moment a name is reassigned to something it cannot resolve. An
un-inferred receiver is silently skipped. Under-reporting is the deliberate
direction: every complaint should be real.

THE INDEX IS NOT COMPLETE, AND THAT DICTATES THE DESIGN. Measured 2026-09-08:
IsoLivingCharacter is absent entirely, so IsoPlayer's inherited surface looks
unknown and a naive pass flags player:getX(); SandboxOptions is missing 5 of
its 55 public methods, getOptionByName among them, which shipping SaucedCarts
code calls. So the checks are split by the kind of evidence they need:

  POSITIVE ("the index says X IS a public field")  -- always on. An incomplete
      index cannot make these wrong, only fewer.
  ABSENCE  ("the index does not list this method") -- only for classes in
      pz_api_complete.txt, where the index has been verified against decompiled
      source. 234 of 822 qualify.

That is why the first run over five real mods produced 239 findings and this
one produces a handful: the noise was entirely absence-claims about classes the
index cannot support them for.

Usage:  python tools/pz_api_check.py [path ...]      (default: media/lua)
        pztest apicheck [path ...]                   (same thing, wired up)
        exit 1 if any call is wrong
"""

import difflib
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Where the index lives. Overridable for CI boxes that put pz-dev-tools
# somewhere else; absent, the tool says so and exits CLEAN rather than failing
# a build over its own missing input.
# ---------------------------------------------------------------------------
INDEX_CANDIDATES = [
    Path(r"C:\Users\Khalen\Code\pz-dev-tools\indexes\java-api"),
    Path.home() / "Code" / "pz-dev-tools" / "indexes" / "java-api",
    Path(__file__).resolve().parents[2] / "pz-dev-tools" / "indexes" / "java-api",
]

# ---------------------------------------------------------------------------
# Java collections. NOT in the index (it covers zombie.* only), and Kahlua
# exposes a PARTIAL surface, which is its own bug source -- the frequency scan
# walked keySet():iterator() inside a bare pcall and was dead from the day it
# was written. Only names CONFIRMED unavailable are flagged; the rest of the
# surface is left alone so this never invents a rule.
# ---------------------------------------------------------------------------
COLLECTION_TYPES = {"ArrayList", "List", "Vector", "Stack", "HashMap", "Map",
                    "HashSet", "Set", "Collection", "LinkedList"}

# Confirmed NOT reachable from Kahlua on any Java collection. Walk an ArrayList
# with size()/get(i); there is no iterator protocol.
COLLECTION_FORBIDDEN = {
    "iterator":     "size() / get(i) -- Kahlua exposes no iterator protocol",
    "listIterator": "size() / get(i)",
    "forEach":      "a numeric for over size() / get(i)",
    "stream":       "a numeric for over size() / get(i)",
}

# ---------------------------------------------------------------------------
# Type seeds: PZ globals whose return class is unambiguous. Deliberately short
# and hand-verified -- a wrong entry here manufactures false positives all the
# way down every chain that starts with it.
# ---------------------------------------------------------------------------
GLOBAL_RETURNS = {
    "getWorld":             "IsoWorld",
    "getCell":              "IsoCell",
    "getPlayer":            "IsoPlayer",
    "getSpecificPlayer":    "IsoPlayer",
    "getSoundManager":      "SoundManager",
    "getScriptManager":     "ScriptManager",
    "getGameTime":          "GameTime",
    "getClimateManager":    "ClimateManager",
    "getSandboxOptions":    "SandboxOptions",
    "getRadioScriptManager": "RadioScriptManager",
}

_IDENT = r"[A-Za-z_]\w*"


# ---------------------------------------------------------------------------
# Index loading
# ---------------------------------------------------------------------------
class Api:
    def __init__(self, root):
        self.root = root
        self.methods = {}    # class -> {name: [return types]}
        self.fields = {}     # class -> {field}
        self.extends = {}    # class -> superclass name
        # Classes the index is VERIFIED complete for -- the only ones we may
        # make ABSENCE claims about. See pz_api_verify_index.py for why: the
        # index is missing IsoLivingCharacter entirely and 5 of SandboxOptions'
        # 55 public methods, so "not in the index" does not mean "not real".
        self.complete = set()
        allow = Path(__file__).with_name("pz_api_complete.txt")
        if allow.exists():
            self.complete = {
                ln.strip() for ln in allow.read_text(encoding="utf-8").splitlines()
                if ln.strip() and not ln.startswith("#")
            }
        sig = re.compile(r"^\s{2}(" + _IDENT + r")\((.*?)\)\s*->\s*(.+?)\s*$")
        fld = re.compile(r"^\s{2}(?:static\s+)?(?:final\s+)?[\w.$<>\[\],\s]+?\s+("
                         + _IDENT + r")\s*$")
        ext = re.compile(r"^#\s*extends\s+(" + _IDENT + r")")
        for f in sorted(root.glob("*.txt")):
            cls = f.stem
            self.methods[cls] = {}
            self.fields[cls] = set()
            section = None
            for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
                m = ext.match(line)
                if m:
                    self.extends[cls] = m.group(1)
                    continue
                if line.startswith("## "):
                    section = line[3:].strip()
                    continue
                # Inner classes carry their own surface; attributing their
                # methods to the outer class would hide real misses.
                if line.startswith("  ### "):
                    section = "__inner__"
                    continue
                if section and section.startswith("Lua-Exposed"):
                    m = sig.match(line)
                    if m:
                        # "-> final String" / "-> abstract C": modifiers leak
                        # into the return column, so strip them.
                        ret = m.group(3).split()[-1]
                        self.methods[cls].setdefault(m.group(1), []).append(ret)
                elif section == "Public Fields":
                    m = fld.match(line)
                    if m:
                        self.fields[cls].add(m.group(1))

    def chain(self, cls):
        """cls and every superclass the index knows, nearest first."""
        out, seen = [], set()
        while cls and cls in self.methods and cls not in seen:
            seen.add(cls)
            out.append(cls)
            cls = self.extends.get(cls)
        return out

    def knows(self, cls):
        return cls in self.methods

    def find_method(self, cls, name):
        """Return (owner, [return types]) or (None, None)."""
        for c in self.chain(cls):
            if name in self.methods[c]:
                return c, self.methods[c][name]
        return None, None

    def find_field(self, cls, name):
        for c in self.chain(cls):
            if name in self.fields[c]:
                return c
        return None

    def all_methods(self, cls):
        out = set()
        for c in self.chain(cls):
            out |= set(self.methods[c])
        return out

    def return_type(self, cls, name):
        """A type only if every overload agrees -- ambiguity ends the chain."""
        _owner, rets = self.find_method(cls, name)
        if not rets:
            return None
        uniq = set(rets)
        if len(uniq) != 1:
            return None
        t = uniq.pop()
        if self.knows(t) or t in COLLECTION_TYPES:
            return t
        return None

    def getter_for(self, cls, field):
        """The accessor that replaces a public-field read, if one exists."""
        cap = field[0].upper() + field[1:]
        for pre in ("get", "is", "has"):
            owner, _ = self.find_method(cls, pre + cap)
            if owner:
                return pre + cap + "()"
        return None


# ---------------------------------------------------------------------------
# Lua source prep -- comments and string literals must not be scanned, or
# every doc comment naming a method becomes a finding.
# ---------------------------------------------------------------------------
def strip_noise(src):
    out, i, n = [], 0, len(src)
    while i < n:
        two = src[i:i + 2]
        if two == "--":
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i)
                j = n if j < 0 else j + len(close)
                out.append(re.sub(r"[^\n]", " ", src[i:j]))
                i = j
                continue
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if src[i] in "\"'":
            q, j = src[i], i + 1
            while j < n and src[j] != q:
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue
        if two == "[[":
            j = src.find("]]", i)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# Inference + checks
# ---------------------------------------------------------------------------
RE_ASSIGN = re.compile(r"(?:^|\s)(?:local\s+)?(" + _IDENT + r")\s*=\s*([^=].*)$")
RE_CALL = re.compile(r"(" + _IDENT + r")\s*:\s*(" + _IDENT + r")\s*\(")
RE_FIELD = re.compile(r"(" + _IDENT + r")\s*\.\s*(" + _IDENT + r")\s*(?!\s*[({\"'])")


def resolve(expr, api, types):
    """Type of a chain expression, or None. Only certainty counts."""
    expr = expr.strip()
    m = re.match(r"^(" + _IDENT + r")\s*\(", expr)
    if m and m.group(1) in GLOBAL_RETURNS:
        cur = GLOBAL_RETURNS[m.group(1)]
        rest = expr[m.end() - 1:]
    else:
        m = re.match(r"^(" + _IDENT + r")\s*:", expr)
        if not m or m.group(1) not in types:
            return None
        cur = types[m.group(1)]
        rest = expr[m.end() - 1:]
    for seg in re.finditer(r":\s*(" + _IDENT + r")\s*\(", rest):
        if cur in COLLECTION_TYPES or not api.knows(cur):
            return None
        cur = api.return_type(cur, seg.group(1))
        if cur is None:
            return None
    return cur


def check_file(path, api, findings):
    src = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
    types = {}
    # Names ever assigned something unresolvable are poisoned for the whole
    # file: without real scope analysis a shadowed local would otherwise be
    # checked against a stale class. Cheap, and it only ever loses findings.
    poisoned = set()
    lines = src.splitlines()

    for raw in lines:
        for m in RE_ASSIGN.finditer(raw):
            name, rhs = m.group(1), m.group(2)
            t = resolve(rhs, api, types)
            if t:
                if name in types and types[name] != t:
                    poisoned.add(name)
                types[name] = t
            else:
                poisoned.add(name)
    for p in poisoned:
        types.pop(p, None)

    for ln, raw in enumerate(lines, 1):
        for m in RE_CALL.finditer(raw):
            recv, name = m.group(1), m.group(2)
            cls = types.get(recv)
            if not cls:
                continue
            if cls in COLLECTION_TYPES:
                if name in COLLECTION_FORBIDDEN:
                    findings.append((path, ln,
                        "%s:%s() -- %s is a Java collection and Kahlua does not "
                        "expose %s(). Use %s." % (recv, name, cls, name,
                                                  COLLECTION_FORBIDDEN[name])))
                continue
            if not api.knows(cls):
                continue
            owner, _ = api.find_method(cls, name)
            if owner:
                continue
            # POSITIVE evidence: the index says this name IS a field. Sound
            # regardless of how complete the index is.
            fowner = api.find_field(cls, name)
            if fowner:
                findings.append((path, ln,
                    "%s:%s() -- %s.%s is a PUBLIC FIELD, not a method." % (
                        recv, name, fowner, name)))
                continue
            # ABSENCE evidence: only trustworthy for a verified-complete class.
            # Everywhere else we say nothing rather than guess -- this is the
            # check that produced player:getX() noise before it was gated.
            if cls not in api.complete:
                continue
            near = difflib.get_close_matches(name, api.all_methods(cls), 3, 0.7)
            hint = ("  Did you mean: " + ", ".join(n + "()" for n in near)) if near else ""
            findings.append((path, ln,
                "%s:%s() -- not in %s's Lua-exposed surface.%s" % (
                    recv, name, cls, hint)))

        for m in RE_FIELD.finditer(raw):
            recv, name = m.group(1), m.group(2)
            cls = types.get(recv)
            if not cls or not api.knows(cls):
                continue
            fowner = api.find_field(cls, name)
            if not fowner:
                continue
            getter = api.getter_for(cls, name)
            findings.append((path, ln,
                "%s.%s -- PUBLIC JAVA FIELD. Kahlua exposes neither reads nor "
                "writes: a read is nil and a write is SILENTLY DISCARDED.%s" % (
                    recv, name, ("  Use %s." % getter) if getter else
                    "  There is no accessor; this cannot be done from Lua.")))


def main(argv):
    index = next((p for p in INDEX_CANDIDATES if p.is_dir()), None)
    if index is None:
        print("[apicheck] java-api index not found; skipping. Looked in:")
        for p in INDEX_CANDIDATES:
            print("    " + str(p))
        return 0
    api = Api(index)

    targets = [Path(a) for a in argv] or [Path("media/lua")]
    files = []
    for t in targets:
        if t.is_dir():
            files += sorted(t.rglob("*.lua"))
        elif t.is_file():
            files.append(t)
    if not files:
        print("[apicheck] no .lua files under %s - nothing to check" %
              ", ".join(str(t) for t in targets))
        return 0

    findings = []
    for f in files:
        check_file(f, api, findings)

    for path, ln, msg in findings:
        print("FAIL %s:%d %s" % (path, ln, msg))
    print("[apicheck] %d file(s), %d class(es) indexed; %d finding(s)" % (
        len(files), len(api.methods), len(findings)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
