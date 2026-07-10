#!/usr/bin/env python3
"""uiprobe -- measure the UIView headless drawcall list mathematically.

The uiview harness renders REAL PZ Lua panels headlessly and emits, per scene, a
JSON display list: every draw op (rect / rectborder / texture / text) with its
x/y/w/h/color, plus the element TREE (each ISUIElement with its rect). This tool
parses that JSON so geometry claims -- "the funnel is centered in the icon
column", "top padding equals bottom padding" -- can be CONFIRMED numerically
before they're asserted, instead of eyeballed off a thumbnail.

    bash ../pztest 2>/dev/null | ./uiprobe.py emit   # capture + cache ALL scenes
    ./uiprobe.py find  <scene> <selector>     # list matching ops/elements + rects
    ./uiprobe.py box   <scene> <selector>     # resolve ONE bbox, print its edges
    ./uiprobe.py gap   <scene> <A> <B>        # edge deltas + axis gaps, A vs B
    ./uiprobe.py between <scene> <X> <A> <B>   # is X's padding between A and B equal?
    ./uiprobe.py center  <scene> <X> <Lo> <Hi> # is X centered between Lo and Hi?
    ./uiprobe.py cols  <scene>                # detect vertical 1px column dividers
    ./uiprobe.py diff  <fileA> <fileB>        # per-element rect diff (harness vs live)

SELECTOR grammar (resolves to a bounding box = union of all matches):
    #12            element id 12 (tree)
    t:Name         tree node whose type CONTAINS "Name"
    n:sub          draw ops whose texture name CONTAINS "sub"
    s:sub          text ops whose string CONTAINS "sub"
    op:texture     ops of that kind (rect|rectborder|texture|text)
    ...append @k   pick only the k-th match (0-based) instead of the union
    ...append /y>580   keep only matches passing a coord predicate (x,y,w,h,r,b)

Examples (SIR inventory):
    ./uiprobe.py between sirinv 't:ISButton/y>580@0' 't:SIR_InventoryPane' 'n:winfoot'
    ./uiprobe.py center  sirinv 'n:sir_ui-funnel' '#0/x<40' ...    # or use cols
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "out", "probe")


# ---- harness capture ------------------------------------------------------
# The harness runs in Git Bash (`bash ../pztest`); Python can't reliably spawn
# that shell on Windows (subprocess picks up WSL bash), so `emit` reads the
# harness stdout from a PIPE instead of shelling out itself:
#     bash ../pztest 2>/dev/null | python uiprobe.py emit
def emit():
    raw = sys.stdin.read()
    scenes = {}
    for m in re.finditer(r"@@UIVIEW_BEGIN:(\w+)@@(.*?)@@UIVIEW_END:\1@@", raw, re.S):
        try:
            scenes[m.group(1)] = json.loads(m.group(2))
        except json.JSONDecodeError:
            pass
    if not scenes:
        print("ERROR: no @@UIVIEW@@ blocks on stdin. Pipe the harness in:\n"
              "  bash ../pztest 2>/dev/null | python uiprobe.py emit", file=sys.stderr)
        sys.exit(1)
    os.makedirs(CACHE, exist_ok=True)
    for name, data in scenes.items():
        with open(os.path.join(CACHE, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(data, f)
    print("cached %d scene(s): %s" % (len(scenes), ", ".join(sorted(scenes))))


def load(scene):
    """Load a scene's JSON from the cache written by `emit`."""
    path = os.path.join(CACHE, scene + ".json")
    if not os.path.exists(path):
        print("ERROR: no cached scene %r. Capture first:\n"
              "  bash ../pztest 2>/dev/null | python uiprobe.py emit" % scene, file=sys.stderr)
        sys.exit(1)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ---- tree + op flattening -------------------------------------------------
def walk_tree(node):
    yield node
    ch = node.get("children") or {}
    for c in (ch.values() if isinstance(ch, dict) else ch):
        yield from walk_tree(c)


def rect_of(item, kind):
    """(x0, y0, x1, y1) for a tree node or an op."""
    if kind == "tree":
        x, y, w, h = item.get("x", 0), item.get("y", 0), item.get("w", 0), item.get("h", 0)
    else:
        x, y, w, h = item.get("x", 0), item.get("y", 0), item.get("w", 0), item.get("h", 0)
    return (x, y, x + w, y + h)


# ---- selector engine ------------------------------------------------------
_PRED = re.compile(r"^([xywrb])\s*([<>]=?|==)\s*(-?\d+(?:\.\d+)?)$")


def _passes(rx, pred):
    if not pred:
        return True
    m = _PRED.match(pred)
    if not m:
        return True
    field, opr, val = m.group(1), m.group(2), float(m.group(3))
    x0, y0, x1, y1 = rx
    cur = {"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0, "r": x1, "b": y1}[field]
    return {"<": cur < val, ">": cur > val, "<=": cur <= val,
            ">=": cur >= val, "==": cur == val}[opr]


def resolve(data, selector):
    """Return (x0, y0, x1, y1) bounding box for a selector, or exit on no match."""
    sel = selector
    idx = None
    pred = None
    # grammar is  base[/pred][@k]  -- strip the @k index first (rightmost),
    # then the /pred, so either can be present in that order
    if "@" in sel:
        sel, k = sel.rsplit("@", 1)
        idx = int(k)
    if "/" in sel:
        sel, pred = sel.split("/", 1)

    matches = []
    if sel.startswith("#"):
        wanted = int(sel[1:])
        for n in walk_tree(data["tree"]):
            if n.get("id") == wanted:
                matches.append(rect_of(n, "tree"))
    elif sel.startswith("t:"):
        needle = sel[2:]
        for n in walk_tree(data["tree"]):
            if needle in str(n.get("type", "")):
                matches.append(rect_of(n, "tree"))
    elif sel.startswith("n:"):
        needle = sel[2:]
        for o in data["ops"]:
            if o.get("op") == "texture" and needle in str(o.get("name", "")):
                matches.append(rect_of(o, "op"))
    elif sel.startswith("s:"):
        needle = sel[2:]
        for o in data["ops"]:
            if o.get("op") == "text" and needle in str(o.get("str", "")):
                matches.append(rect_of(o, "op"))
    elif sel.startswith("op:"):
        needle = sel[3:]
        for o in data["ops"]:
            if o.get("op") == needle:
                matches.append(rect_of(o, "op"))
    else:
        print("ERROR: bad selector %r (see --help)" % selector, file=sys.stderr)
        sys.exit(2)

    matches = [r for r in matches if _passes(r, pred)]
    if not matches:
        print("ERROR: selector %r matched nothing" % selector, file=sys.stderr)
        sys.exit(3)
    if idx is not None:
        return matches[idx]
    # union bbox
    return (min(r[0] for r in matches), min(r[1] for r in matches),
            max(r[2] for r in matches), max(r[3] for r in matches))


def _fmt(r):
    return "x=%g..%g (w=%g)  y=%g..%g (h=%g)" % (r[0], r[2], r[2] - r[0], r[1], r[3], r[3] - r[1])


# ---- commands -------------------------------------------------------------
def cmd_find(scene, selector):
    data = load(scene)
    sel = selector.split("/")[0].split("@")[0]
    pred = selector.split("/", 1)[1] if "/" in selector else None
    rows = []
    if sel.startswith(("t:", "#")):
        for n in walk_tree(data["tree"]):
            hit = (n.get("id") == int(sel[1:])) if sel.startswith("#") else (sel[2:] in str(n.get("type", "")))
            if hit:
                r = rect_of(n, "tree")
                if _passes(r, pred):
                    rows.append(("#%s %s" % (n.get("id"), n.get("type")), r))
    else:
        for o in data["ops"]:
            label = None
            if sel.startswith("n:") and o.get("op") == "texture" and sel[2:] in str(o.get("name", "")):
                label = "tex %s" % o.get("name")
            elif sel.startswith("s:") and o.get("op") == "text" and sel[2:] in str(o.get("str", "")):
                label = "txt %r" % o.get("str")
            elif sel.startswith("op:") and o.get("op") == sel[3:]:
                label = "%s %s" % (o.get("op"), o.get("name", o.get("str", "")))
            if label:
                r = rect_of(o, "op")
                if _passes(r, pred):
                    rows.append((label, r))
    print("%d match(es) for %r:" % (len(rows), selector))
    for label, r in rows[:60]:
        print("  %-34s %s" % (label[:34], _fmt(r)))
    if len(rows) > 60:
        print("  ... (%d more)" % (len(rows) - 60))


def cmd_box(scene, selector):
    r = resolve(load(scene), selector)
    print("%s : %s" % (selector, _fmt(r)))


def cmd_gap(scene, a, b):
    data = load(scene)
    A, B = resolve(data, a), resolve(data, b)
    print("A %-24s %s" % (a, _fmt(A)))
    print("B %-24s %s" % (b, _fmt(B)))
    print("  edge deltas (A relative to B):")
    print("    left   A.x - B.x = %g" % (A[0] - B[0]))
    print("    right  B.r - A.r = %g" % (B[2] - A[2]))
    print("    top    A.y - B.y = %g" % (A[1] - B[1]))
    print("    bottom B.b - A.b = %g" % (B[3] - A[3]))
    # axis gaps (positive = clear space between; negative = overlap)
    hgap = max(B[0] - A[2], A[0] - B[2])
    vgap = max(B[1] - A[3], A[1] - B[3])
    print("  horizontal gap: %s" % ("%g" % hgap if hgap >= 0 else "overlap %g" % -hgap))
    print("  vertical   gap: %s" % ("%g" % vgap if vgap >= 0 else "overlap %g" % -vgap))


def cmd_between(scene, x, a, b, axis="y"):
    data = load(scene)
    X, A, B = resolve(data, x), resolve(data, a), resolve(data, b)
    if axis == "y":
        lo, hi = (A, B) if A[1] <= B[1] else (B, A)
        before = X[1] - lo[3]     # gap above X (X.top - upper.bottom)
        after = hi[1] - X[3]      # gap below X (lower.top - X.bottom)
        names = ("top", "bottom")
    else:
        lo, hi = (A, B) if A[0] <= B[0] else (B, A)
        before = X[0] - lo[2]
        after = hi[0] - X[2]
        names = ("left", "right")
    print("X   %-24s %s" % (x, _fmt(X)))
    print("lo  %-24s %s" % (a if lo is A else b, _fmt(lo)))
    print("hi  %-24s %s" % (b if hi is B else a, _fmt(hi)))
    verdict = "EQUAL" if abs(before - after) <= 1 else "UNEQUAL (off by %g)" % abs(before - after)
    print("  %-6s padding = %g   %-6s padding = %g   -> %s"
          % (names[0], before, names[1], after, verdict))


def _edge(data, tok, axis, side):
    """A boundary coordinate: a bare number is used verbatim, else the resolved
    box's near edge (side 'lo' -> its far edge; 'hi' -> its near edge)."""
    try:
        return float(tok)
    except ValueError:
        pass
    r = resolve(data, tok)
    if axis == "x":
        return r[2] if side == "lo" else r[0]
    return r[3] if side == "lo" else r[1]


def cmd_center(scene, x, lo, hi, axis="x"):
    data = load(scene)
    X = resolve(data, x)
    i = 0 if axis == "x" else 1
    j = 2 if axis == "x" else 3
    lo_edge = _edge(data, lo, axis, "lo")
    hi_edge = _edge(data, hi, axis, "hi")
    span_mid = (lo_edge + hi_edge) / 2.0
    x_mid = (X[i] + X[j]) / 2.0
    off = x_mid - span_mid
    verdict = "CENTERED" if abs(off) <= 1 else "OFF-CENTER by %g" % off
    print("X   %-22s %s" % (x, _fmt(X)))
    print("column [%g .. %g]  mid=%g   X.mid=%g   -> %s" % (lo_edge, hi_edge, span_mid, x_mid, verdict))


def cmd_cols(scene):
    data = load(scene)
    seen = {}
    for o in data["ops"]:
        if o.get("w") == 1 and (o.get("h") or 0) > 40:
            x = o.get("x")
            seen.setdefault(x, (o.get("y"), o.get("h"), o.get("a")))
    print("vertical 1px dividers (column starts), left to right:")
    for x in sorted(seen):
        y, h, a = seen[x]
        print("  x=%-5g  y=%g..%g  alpha=%g" % (x, y, y + h, a))


def cmd_diff(file_a, file_b, tol=1.0):
    with open(file_a, encoding="utf-8") as f:
        A = json.load(f)
    with open(file_b, encoding="utf-8") as f:
        B = json.load(f)
    def index(d):
        out = {}
        for n in walk_tree(d["tree"]):
            out.setdefault(str(n.get("type")), []).append(rect_of(n, "tree"))
        return out
    ia, ib = index(A), index(B)
    print("rect diff  %s (A)  vs  %s (B)  tol=%g" % (os.path.basename(file_a), os.path.basename(file_b), tol))
    for typ in sorted(set(ia) | set(ib)):
        ra, rb = ia.get(typ, []), ib.get(typ, [])
        for k in range(max(len(ra), len(rb))):
            if k >= len(ra):
                print("  + %s[%d] only in B: %s" % (typ, k, _fmt(rb[k]))); continue
            if k >= len(rb):
                print("  - %s[%d] only in A: %s" % (typ, k, _fmt(ra[k]))); continue
            d = [rb[k][i] - ra[k][i] for i in range(4)]
            if any(abs(v) > tol for v in d):
                print("  ~ %s[%d]  dx0=%g dy0=%g dx1=%g dy1=%g" % (typ, k, *d))


# ---- dispatch -------------------------------------------------------------
def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, rest = sys.argv[1], sys.argv[2:]
    opts = {a.split("=")[0].lstrip("-"): a.split("=", 1)[1] for a in rest if a.startswith("--") and "=" in a}
    pos = [a for a in rest if not a.startswith("--")]
    try:
        if cmd == "emit":
            emit()
        elif cmd == "find":
            cmd_find(pos[0], pos[1])
        elif cmd == "box":
            cmd_box(pos[0], pos[1])
        elif cmd == "gap":
            cmd_gap(pos[0], pos[1], pos[2])
        elif cmd == "between":
            cmd_between(pos[0], pos[1], pos[2], pos[3], opts.get("axis", "y"))
        elif cmd == "center":
            cmd_center(pos[0], pos[1], pos[2], pos[3], opts.get("axis", "x"))
        elif cmd == "cols":
            cmd_cols(pos[0])
        elif cmd == "diff":
            cmd_diff(pos[0], pos[1], float(opts.get("tol", 1.0)))
        else:
            print("unknown command %r (see --help)" % cmd, file=sys.stderr)
            sys.exit(2)
    except IndexError:
        print("ERROR: missing argument for '%s' (see --help)" % cmd, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
