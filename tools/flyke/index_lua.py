"""Static index of a mod's Lua functions, for .flyke flow charts.

    python index_lua.py <media/lua dir> <root global> <out.json>

For every `function A.b(...)` / `function A:b(...)` / `A.b = function(...)`,
records the function's RUNTIME path under the root global (resolving local
aliases: `local Mu = {}` ... `G.Mutation = Mu` with `local G = VorpallySauced.Genome`
gives Mu -> Genome.Mutation), its file, first and last line, and the `---`
doc comment above it. The tracer names calls by the same runtime paths, so the
two join on the name.
"""
import json
import os
import re
import sys

FN_DEF = re.compile(r"^\s*function\s+([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)[.:]([A-Za-z_]\w*)\s*\(")
FN_ASSIGN = re.compile(r"^\s*([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)\.([A-Za-z_]\w*)\s*=\s*function\s*\(")
LOCAL_ALIAS = re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_][\w.]*)\s*(?:or\s*\{\s*\})?\s*(?:--.*)?$")
LOCAL_TABLE = re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=\s*\{\s*\}\s*(?:--.*)?$")
STORE = re.compile(r"^\s*([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)\s*=\s*([A-Za-z_]\w*)\s*(?:--.*)?$")


def resolve(expr, aliases, root):
    """'G.Mutation' -> 'Genome.Mutation' (relative to root), or None."""
    parts = expr.split(".")
    head = parts[0]
    if head == root:
        base = []
    elif head in aliases and aliases[head] is not None:
        base = aliases[head].split(".") if aliases[head] else []
    else:
        return None
    return ".".join(base + parts[1:])


def index_file(path, root):
    lines = open(path, encoding="utf8", errors="ignore").read().split("\n")
    aliases = {}            # local name -> runtime path ("" = the root itself)
    pending = set()         # local tables whose path is decided later
    for ln in lines:
        m = LOCAL_ALIAS.match(ln)
        if m:
            p = resolve(m.group(2), aliases, root) if m.group(2) != root else ""
            if p is not None:
                aliases[m.group(1)] = p
            continue
        m = LOCAL_TABLE.match(ln)
        if m:
            pending.add(m.group(1))
            continue
        m = STORE.match(ln)
        if m and m.group(2) in pending:
            p = resolve(m.group(1), aliases, root)
            if p is not None:
                aliases[m.group(2)] = p
    out = []
    starts = []
    for i, ln in enumerate(lines):
        m = FN_DEF.match(ln) or FN_ASSIGN.match(ln)
        if not m:
            continue
        mod = resolve(m.group(1), aliases, root)
        if mod is None:
            continue
        doc = []
        j = i - 1
        while j >= 0 and lines[j].lstrip().startswith("--"):
            doc.insert(0, lines[j].strip().lstrip("-").strip())
            j -= 1
        starts.append(i)
        out.append({"id": (mod + "." if mod else "") + m.group(2), "module": mod, "fn": m.group(2),
                    "file": path.replace("\\", "/"), "line": i + 1, "doc": " ".join(d for d in doc if d)})
    # a function ends at the first unindented `end` after it starts (top-level
    # definitions close at column 0); scanning BACK from the next indexed one
    # swallowed every local helper in between (isValidAnyWeapon read 752-1038)
    for f in out:
        end = None
        for i in range(f["line"], len(lines)):
            if re.match(r"^end(\s|$)", lines[i]):
                end = i + 1
                break
        f["endLine"] = end or f["line"]
    return out


def main():
    src, root, out = sys.argv[1], sys.argv[2], sys.argv[3]
    allf = []
    for dp, _, fs in os.walk(src):
        if "Tests" in dp.replace("\\", "/").split("/"):
            continue
        for f in fs:
            if f.endswith(".lua"):
                allf.extend(index_file(os.path.join(dp, f), root))
    by = {}
    for f in allf:
        by.setdefault(f["id"], f)
    json.dump({"root": root, "functions": by}, open(out, "w"), indent=1)
    documented = sum(1 for f in by.values() if f["doc"])
    print(f"{out}: {len(by)} functions, {documented} with a doc comment")


if __name__ == "__main__":
    main()
