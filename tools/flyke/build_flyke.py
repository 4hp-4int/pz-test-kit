"""Build a .flyke flow chart from a SousVide call trace and a static index.

    python build_flyke.py <trace output> <index.json> <out.flyke> [--name NAME]

Trace lines (flow_trace_tests.lua): "[FLYKE] i|parent|depth|step|id|args|ret|entry"
and one "[FLYKE-META] k=v|k=v". Index: index_lua.py's output.

A .flyke is JSON:
  meta     scenario, counts
  nodes    one per function or entry event: id, module, kind (entry|fn),
           calls, column (shortest call depth from an entry), file, line,
           endLine, summary (the doc comment; "" when the source has none),
           in / out (the commonest shapes of the data, with counts), ai (an AI
           summary from summaries.json beside the output, when present)
  edges    caller -> callee: count, a sample of the data passed
  timeline per entry call, in order: the step, the entry and its call tree
           (ids with depth), truncated
"""
import collections
import json
import sys

ENTRY_TEXT = {
    "OnHitZombie": "A melee hit lands on a zombie (engine event).",
    "OnZombieDead": "A zombie dies (engine event).",
    "OnTick": "Every game tick (engine event).",
    "OnWeaponHitCharacter": "A weapon hits a character, zombie or player (engine event).",
    "OnEquipPrimary": "The player puts a weapon in the main hand (engine event).",
    "OnWeaponSwing": "The player starts a swing (engine event).",
    "OnPlayerAttackFinished": "A swing finishes (engine event).",
}


def main():
    trace, index, out = sys.argv[1], sys.argv[2], sys.argv[3]
    name = sys.argv[sys.argv.index("--name") + 1] if "--name" in sys.argv else "flow"
    idx = json.load(open(index))["functions"]
    meta, calls = {}, []
    for line in open(trace, encoding="utf8", errors="ignore"):
        if line.startswith("[FLYKE-META] "):
            for kv in line[13:].strip().split("|"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    meta[k] = v
        elif line.startswith("[FLYKE] "):
            p = line[8:].rstrip("\n").split("|")
            if len(p) < 7:
                continue
            calls.append({"i": int(p[0]), "parent": int(p[1]), "depth": int(p[2]), "step": p[3], "id": p[4],
                          "args": p[5], "ret": p[6], "entry": len(p) > 7 and p[7] == "entry"})
    by_i = {c["i"]: c for c in calls}

    nodes = {}
    edges = {}
    for c in calls:
        n = nodes.get(c["id"])
        if not n:
            entry = c["entry"]
            ev = c["id"].split(" ", 1)[1] if entry else None
            f = idx.get(c["id"], {})
            n = nodes[c["id"]] = {
                "id": c["id"], "kind": "entry" if entry else "fn",
                "module": ("events" if c["id"].startswith("event ") else "buses") if entry else (f.get("module") or c["id"].rsplit(".", 1)[0] if "." in c["id"] else "VorpallySauced"),
                "calls": 0, "column": 99, "file": f.get("file"), "line": f.get("line"), "endLine": f.get("endLine"),
                "summary": ENTRY_TEXT.get(ev, ("A VorpallySauced event bus fires." if entry else f.get("doc", ""))),
                "in": collections.Counter(), "out": collections.Counter(), "steps": collections.Counter(),
            }
        n["calls"] += 1
        n["in"][c["args"]] += 1
        n["out"][c["ret"]] += 1
        n["steps"][c["step"].split(" ")[0]] += 1
        # column: distance from the nearest entry above it
        d, cur = 0, c
        while cur and not cur["entry"] and cur["parent"]:
            d += 1
            cur = by_i.get(cur["parent"])
        n["column"] = min(n["column"], 0 if c["entry"] else (d if cur and cur["entry"] else d + 1))
        if c["parent"]:
            par = by_i.get(c["parent"])
            if par:
                key = (par["id"], c["id"])
                e = edges.setdefault(key, {"from": par["id"], "to": c["id"], "count": 0, "data": c["args"]})
                e["count"] += 1

    timeline = []
    children = collections.defaultdict(list)
    for c in calls:
        children[c["parent"]].append(c)

    def tree(c, depth, acc):
        if len(acc) >= 60:
            return
        acc.append({"id": c["id"], "d": depth, "args": c["args"], "ret": c["ret"]})
        for ch in children[c["i"]]:
            tree(ch, depth + 1, acc)

    for c in children[0]:
        acc = []
        tree(c, 0, acc)
        timeline.append({"step": c["step"], "entry": c["id"], "calls": acc, "total": sum(1 for _ in acc)})

    out_nodes = []
    for n in nodes.values():
        n["in"] = [[k, v] for k, v in n["in"].most_common(3)]
        n["out"] = [[k, v] for k, v in n["out"].most_common(3)]
        n["steps"] = dict(n["steps"])
        out_nodes.append(n)
    # AI summaries (one sentence per block on what it does with the data), if
    # a summaries.json sits beside the output: { id: sentence }
    import os
    sp = os.path.join(os.path.dirname(os.path.abspath(out)), "summaries.json")
    if os.path.isfile(sp):
        ai = json.load(open(sp, encoding="utf8"))
        for n in out_nodes:
            if n["id"] in ai:
                n["ai"] = ai[n["id"]]
    doc = {"flyke": 1, "name": name, "meta": meta, "nodes": out_nodes, "edges": list(edges.values()), "timeline": timeline}
    json.dump(doc, open(out, "w"), indent=1)
    summarized = sum(1 for n in out_nodes if n["summary"])
    print(f"{out}: {len(out_nodes)} blocks ({summarized} with a summary), {len(edges)} edges, {len(timeline)} entry calls, from {len(calls)} calls")


if __name__ == "__main__":
    main()
