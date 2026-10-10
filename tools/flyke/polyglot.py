"""Polyglot .flyke: a repo's functions across languages, and the contracts
that connect the languages, derived deterministically from the code.

    uv run --python 3.11 --with tree-sitter --with tree-sitter-language-pack \\
        python polyglot.py <repo root> <out.flyke> [--name NAME] [--include GLOB ...] [--exclude DIR ...]

Parses Python, JavaScript (also <script> blocks inside HTML), Lua and SQL with
tree-sitter (one maintained grammar per language). Blocks are functions (and
SQL tables, and data files). Edges, every one from something written in the
code, never inferred by a model:

  call    a call resolved to a definition: same file first, then a name that
          is unique in that language; an ambiguous name is skipped, not guessed
  http    a client's path literal ("/v1/ingest") -> the server function that
          compares the request path against it (=== / startsWith)
  sql     a query string naming a table -> that CREATE TABLE
  file    a data-file name literal (vpsledger-...jsonl) -> a file block
  mirror  the same distinctive snake_case literal (a check id) in functions of
          two languages: the port-parity link between two implementations

Same code in, same chart out: the output is sorted and carries no timestamps,
so it can be regenerated and diffed like a lockfile.
"""
import collections
import fnmatch
import json
import os
import re
import sys

from tree_sitter_language_pack import get_parser

LANG_OF = {".py": "python", ".js": "javascript", ".mjs": "javascript", ".lua": "lua", ".html": "html", ".sql": "sql"}
FN_TYPES = {
    "python": {"function_definition"},
    "javascript": {"function_declaration", "method_definition", "function_expression", "arrow_function", "generator_function_declaration"},
    "lua": {"function_declaration", "function_definition"},
}
CALL_TYPES = {"python": {"call"}, "javascript": {"call_expression"}, "lua": {"function_call"}}
STRING_TYPES = {"string", "template_string", "string_content"}
HTTP_PATH = re.compile(r"^/[a-z0-9_.-]+(/[a-z0-9_.${}-]*)*$")
FILE_NAME = re.compile(r"^[\w-]+\.(jsonl|json|csv|txt|log|png|sql|ini|dat)$", re.I)
FILE_PREFIX = re.compile(r"^[a-z][\w]+-$")
MIRROR = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+){1,6}$")
SQL_REF = re.compile(r"\b(?:FROM|INTO|UPDATE|JOIN|TABLE(?:\s+IF\s+NOT\s+EXISTS)?)\s+([A-Za-z_][A-Za-z0-9_]*)", re.I)


def text(node, src):
    return src[node.start_byte:node.end_byte].decode("utf8", "replace")


def walk(node):
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(reversed(n.children))


def fn_name(node, src, lang):
    """A function node's name, or None for a nameless one we can't place."""
    name_node = node.child_by_field_name("name")
    if name_node is not None:
        return text(name_node, src)
    p = node.parent
    if lang == "javascript" and p is not None:
        if p.type == "variable_declarator" and p.child_by_field_name("name") is not None:
            return text(p.child_by_field_name("name"), src)
        if p.type in ("pair",) and p.child_by_field_name("key") is not None:
            return text(p.child_by_field_name("key"), src).strip("'\"")
        if p.type == "assignment_expression" and p.child_by_field_name("left") is not None:
            return text(p.child_by_field_name("left"), src).split(".")[-1]
    if lang == "lua" and p is not None:
        # x = function / local x = function / R.x = function: the name is the
        # variable at the same position (a forward-declared `local exec` then
        # `exec = function` hid Runtime's action executor from the map)
        if p.type == "expression_list" and p.parent is not None and p.parent.type == "assignment_statement":
            vl = next((c for c in p.parent.named_children if c.type == "variable_list"), None)
            idx = p.named_children.index(node) if node in p.named_children else -1
            if vl is not None and 0 <= idx < len(vl.named_children):
                return text(vl.named_children[idx], src)
        # { name = function ... }
        if p.type == "field" and p.child_by_field_name("name") is not None:
            return text(p.child_by_field_name("name"), src)
    return None


def doc_of(node, src, lang):
    if lang == "python":
        body = node.child_by_field_name("body")
        if body is not None and body.children and body.children[0].type == "expression_statement":
            s = body.children[0].children[0] if body.children[0].children else None
            if s is not None and s.type == "string":
                return text(s, src).strip("\"' \n").split("\n\n")[0].replace("\n", " ").strip()
        return ""
    # a comment immediately above (through a wrapping declaration)
    target = node
    while target.parent is not None and target.parent.type in ("variable_declarator", "lexical_declaration", "export_statement", "pair", "assignment_expression", "expression_statement",
                                                               "expression_list", "assignment_statement", "variable_declaration", "field"):
        target = target.parent
    prev, out = target.prev_sibling, []
    while prev is not None and prev.type == "comment":
        out.insert(0, re.sub(r"^\s*(//+|/\*+|\*+/?|--+)\s?", "", text(prev, src), flags=re.M).strip())
        prev = prev.prev_sibling
    return " ".join(x for x in out if x)[:400]


def string_value(node, src):
    t = text(node, src)
    if node.type == "template_string":
        return t.strip("`")
    if len(t) >= 2 and t[0] in "\"'" and t[-1] == t[0]:
        return t[1:-1]
    if t.startswith(('"""', "'''")):
        return t[3:-3]
    return t.strip("\"'")


class Repo:
    def __init__(self, root):
        self.root = root
        self.fns = {}            # id -> block
        self.by_name = collections.defaultdict(list)   # (lang, name) -> ids
        self.calls = []          # (caller id, callee name, lang, file)
        self.strings = []        # (fn id, value, node kind, parent text)
        self.tables = {}         # name -> block id

    def add_fn(self, rel, lang, node, src, line_off=0):
        name = fn_name(node, src, lang)
        if not name:
            return None
        start, end = node.start_point[0] + 1 + line_off, node.end_point[0] + 1 + line_off
        fid = f"{rel}::{name}"
        if fid in self.fns:
            fid = f"{rel}::{name}@{start}"
        self.fns[fid] = {"id": fid, "kind": "fn", "lang": lang, "module": rel, "fn": name,
                         "file": rel, "line": start, "endLine": end,
                         "summary": doc_of(node, src, lang)}
        self.by_name[(lang, name)].append(fid)
        return fid

    def parse_code(self, rel, lang, src, line_off=0):
        tree = get_parser(lang).parse(src)
        owner = {}
        for n in walk(tree.root_node):
            if n.type in FN_TYPES.get(lang, ()):
                fid = self.add_fn(rel, lang, n, src, line_off)
                if fid:
                    owner[n.id] = fid
        def enclosing(n):
            p = n.parent
            while p is not None:
                if p.id in owner:
                    return owner[p.id]
                p = p.parent
            return f"{rel}::<module>"
        for n in walk(tree.root_node):
            if n.type in CALL_TYPES.get(lang, ()):
                fnode = n.child_by_field_name("function") or (n.children[0] if n.children else None)
                if fnode is None:
                    continue
                callee = text(fnode, src).split(".")[-1].split(":")[-1].strip()
                if re.match(r"^[A-Za-z_]\w*$", callee):
                    self.calls.append((enclosing(n), callee, lang, rel))
            elif n.type in ("string", "template_string") and (n.parent is None or n.parent.type not in ("string",)):
                val = string_value(n, src)
                par = n.parent
                ctx = text(par, src)[:160] if par is not None else ""
                # the wider context: up to the enclosing statement (a test like
                # startswith(...) and endswith(".jsonl") spans sibling expressions)
                anc = par.parent if par is not None else None
                for _ in range(3):
                    if anc is None or anc.parent is None or anc.type.endswith("statement") or anc.type in ("if_statement", "return_statement"):
                        break
                    anc = anc.parent
                ctx2 = text(anc, src)[:300] if anc is not None else ""
                self.strings.append((enclosing(n), val, ctx, ctx2, lang, rel))
        # a module-level constant (local X = "literal" / X = "literal" / const X = "literal")
        # counts as that literal in every function of the file that names X
        consts = {}
        for fid, val, ctx, ctx2, l2, r2 in self.strings:
            if r2 == rel and fid == f"{rel}::<module>":
                m = re.match(r"^\s*(?:local\s+|const\s+|let\s+|var\s+)?([A-Za-z_]\w*)\s*=\s*['\"`]", ctx) or                     re.match(r"^\s*(?:local\s+|const\s+|let\s+|var\s+)?([A-Za-z_]\w*)\s*=\s*['\"`]", ctx2)
                if m:
                    consts[m.group(1)] = val
        if consts:
            for n in walk(tree.root_node):
                if n.type == "identifier" and text(n, src) in consts:
                    fid = enclosing(n)
                    if fid != f"{rel}::<module>":
                        val = consts[text(n, src)]
                        par = n.parent
                        self.strings.append((fid, val, text(par, src)[:160] if par else "",
                                             text(par.parent, src)[:200] if par and par.parent else "", lang, rel))
        mod_id = f"{rel}::<module>"
        if mod_id not in self.fns:
            self.fns[mod_id] = {"id": mod_id, "kind": "module", "lang": lang, "module": rel, "fn": "<module>",
                                "file": rel, "line": 1, "endLine": None,
                                "summary": "Top-level code of the file."}

    def parse_file(self, rel):
        path = os.path.join(self.root, rel)
        lang = LANG_OF.get(os.path.splitext(rel)[1].lower())
        src = open(path, "rb").read()
        if lang == "sql":
            for m in re.finditer(rb"CREATE TABLE(?: IF NOT EXISTS)?\s+([A-Za-z_]\w*)", src, re.I):
                name = m.group(1).decode()
                line = src[:m.start()].count(b"\n") + 1
                tid = f"table {name}"
                self.tables[name] = tid
                self.fns.setdefault(tid, {"id": tid, "kind": "table", "lang": "sql", "module": rel, "fn": name,
                                          "file": rel, "line": line, "endLine": line + 12,
                                          "summary": f"SQL table {name} ({rel})."})
            return
        if lang == "html":
            tree = get_parser("html").parse(src)
            for n in walk(tree.root_node):
                if n.type == "script_element":
                    raw = [c for c in n.children if c.type == "raw_text"]
                    if raw:
                        body = src[raw[0].start_byte:raw[0].end_byte]
                        self.parse_code(rel, "javascript", body, line_off=raw[0].start_point[0])
            return
        if lang:
            self.parse_code(rel, lang, src)


def build(root, includes, excludes, name, also=()):
    repo = Repo(root)
    files = []
    for extra, label in also:
        sub = Repo(extra)
        for dp, dns, fs in os.walk(extra):
            dns[:] = sorted(d for d in dns if not d.startswith(".") and d not in excludes)
            for f in sorted(fs):
                if os.path.splitext(f)[1].lower() in LANG_OF:
                    rel = os.path.relpath(os.path.join(dp, f), extra).replace("\\", "/")
                    sub.parse_file(rel)
        # adopt its blocks under LABEL/
        def relabel(x):
            return label + "/" + x if not x.startswith(("table ", "file ")) else x
        for fid, fn in sub.fns.items():
            fn = dict(fn, id=relabel(fid), module=label + "/" + fn["module"],
                      file=(label + "/" + fn["file"]) if fn.get("file") else None, external=True)
            repo.fns[fn["id"]] = fn
            repo.by_name[(fn["lang"], fn["fn"])].append(fn["id"])
        repo.calls += [(relabel(a), b, l, label + "/" + r) for a, b, l, r in sub.calls]
        repo.strings += [(relabel(a), v, c, c2, l, label + "/" + r) for a, v, c, c2, l, r in sub.strings]
        repo.tables.update(sub.tables)
    for dp, dns, fs in os.walk(root):
        dns[:] = sorted(d for d in dns if not d.startswith(".") and d not in excludes and d != "node_modules")
        for f in sorted(fs):
            rel = os.path.relpath(os.path.join(dp, f), root).replace("\\", "/")
            if os.path.splitext(f)[1].lower() in LANG_OF and (not includes or any(fnmatch.fnmatch(rel, g) for g in includes)):
                files.append(rel)
    for rel in files:
        repo.parse_file(rel)

    edges = {}
    def edge(a, b, kind, label=""):
        if a == b or a not in repo.fns or b not in repo.fns:
            return
        e = edges.setdefault((a, b, kind), {"from": a, "to": b, "kind": kind, "count": 0, "data": label})
        e["count"] += 1
        if label and label not in e["data"]:
            e["data"] = (e["data"] + ", " + label).strip(", ")[:160]

    # call edges
    for caller, callee, lang, rel in repo.calls:
        same = [f for f in repo.by_name.get((lang, callee), []) if repo.fns[f]["module"] == rel]
        cands = same or repo.by_name.get((lang, callee), [])
        if len(cands) == 1:
            edge(caller, cands[0], "call")

    # http: server side = a path literal compared against the request path
    routes = []   # (path literal, server fn, is prefix)
    clients = []  # (literal, fn)
    for fid, val, ctx, ctx2, lang, rel in repo.strings:
        if not HTTP_PATH.match(val.split("?")[0]) or val.count("/") < 2:
            continue
        if re.search(r"(===|==)\s*['\"`]" + re.escape(val), ctx + ctx2) or ".startsWith(" in ctx2:
            routes.append((val, fid, ".startsWith(" in ctx2))
        else:
            clients.append((val, fid))
    for val, cfn in clients:
        path = val.split("?")[0]
        for rv, sfn, prefix in routes:
            if (path == rv) or (prefix and path.startswith(rv)) or (re.sub(r"\$\{[^}]*\}.*$", "", path) == rv and prefix):
                edge(cfn, sfn, "http", rv)

    # sql: query strings naming a table
    for fid, val, ctx, ctx2, lang, rel in repo.strings:
        for m in SQL_REF.finditer(val):
            t = m.group(1)
            if t in repo.tables:
                edge(fid, repo.tables[t], "sql", t)

    # file contracts: data-file names (journals). Patterns first, so a concrete
    # name (vpsledger-journal.jsonl) joins the pattern that matches it
    # (vpsledger-*.jsonl): the writer and the reader meet at one block.
    file_refs = []
    for fid, val, ctx, ctx2, lang, rel in repo.strings:
        is_name = bool(FILE_NAME.match(val))
        # a bare prefix is a file only when the same code tests a file
        # extension or lists a directory (not an attribute prefix like aria-)
        is_prefix = bool(FILE_PREFIX.match(val)) and re.search(r"start[sS]?[wW]ith|:sub\(|find\(", ctx + ctx2)             and re.search(r"ends[wW]ith\(\s*['\"]\.[a-z0-9]+|listdir|readdir|scandir|glob\(", ctx + ctx2)
        if is_name or is_prefix:
            ext = re.search(r"endswith\(['\"](\.[a-z0-9]+)", ctx2)
            key = val if is_name else val + "*" + (ext.group(1) if ext else "")
            # which way the data goes, when the code says so: a writer points
            # into the file, the file points at a reader
            near = ctx + " " + ctx2
            mode = "write" if re.search(r"Writer|\.write|open\([^)]*['\"][wa]", near) else                    "read" if re.search(r"Reader|listdir|readdir|scandir|glob\(|startswith|\.read|open\(", near) else None
            file_refs.append((fid, key, mode))
    patterns = sorted({k for _, k, _m in file_refs if "*" in k})
    for fid, key, mode in file_refs:
        if "*" not in key:
            for pat in patterns:
                if fnmatch.fnmatch(key, pat):
                    key = pat
                    break
        nid = f"file {key}"
        repo.fns.setdefault(nid, {"id": nid, "kind": "file", "lang": "data", "module": "data files", "fn": key,
                                  "file": None, "line": None, "endLine": None,
                                  "summary": f"A data file named in the code: {key}."})
        if mode == "read":
            edge(nid, fid, "file", key + " (read)")
        else:
            edge(fid, nid, "file", key + (" (write)" if mode == "write" else ""))

    # mirror: distinctive snake_case literals shared across languages
    where = collections.defaultdict(set)
    for fid, val, ctx, ctx2, lang, rel in repo.strings:
        if MIRROR.match(val) and len(val) >= 8:
            where[val].add((lang, fid))
    pair_lits = collections.defaultdict(list)
    for val, occ in where.items():
        langs = {l for l, _ in occ}
        if len(langs) < 2 or len(occ) > 10:
            continue
        occ = sorted(occ)
        for i, (la, fa) in enumerate(occ):
            for lb, fb in occ[i + 1:]:
                if la != lb:
                    pair_lits[(fa, fb)].append(val)
    for (fa, fb), lits in pair_lits.items():
        if len(lits) >= 2:
            e = edges.setdefault((fa, fb, "mirror"), {"from": fa, "to": fb, "kind": "mirror", "count": len(lits),
                                                      "data": ", ".join(sorted(lits))[:200]})

    # drop module pseudo-blocks nothing touches; layer by longest path
    used = set()
    for (a, b, k) in edges:
        used.add(a); used.add(b)
    nodes = {k: v for k, v in repo.fns.items() if v["kind"] != "module" or k in used}
    out_e = collections.defaultdict(list)
    has_in = set()
    for (a, b, k), e in edges.items():
        if k != "mirror" and a in nodes and b in nodes:
            out_e[a].append(b); has_in.add(b)
    depth = {}
    def dfs(n, d, seen):
        if depth.get(n, -1) >= d or n in seen or d > 40:
            return
        depth[n] = d
        seen.add(n)
        for m in out_e[n]:
            dfs(m, d + 1, seen)
        seen.discard(n)
    roots = sorted(n for n in nodes if n not in has_in and out_e[n])
    for r in roots:
        dfs(r, 0, set())
    for n in nodes.values():
        n["column"] = depth.get(n["id"], 0)
        n["calls"] = sum(e["count"] for (a, b, k), e in edges.items() if b == n["id"]) or 1
        n["in"] = []
        n["out"] = []
        n["steps"] = {}

    # "entry points": roots with their reachable call trees (for the left panel)
    timeline = []
    for r in roots:
        acc, seen = [], set()
        def tree(n, d):
            if len(acc) >= 60 or n in seen:
                return
            seen.add(n)
            acc.append({"id": n, "d": d, "args": "", "ret": ""})
            for m in sorted(out_e[n]):
                tree(m, d + 1)
        tree(r, 0)
        timeline.append({"step": nodes[r]["lang"] + " · " + nodes[r]["module"], "entry": r, "calls": acc})

    # paths in blocks are relative to the repo root (the folder holding flow/);
    # "external" blocks (--also) name their source by label, not a path here
    doc = {"flyke": 1, "name": name, "static": True,
           "meta": {"repo": os.path.basename(os.path.abspath(root)), "files": str(len(files)),
                    "calls": str(sum(1 for e in edges.values() if e["kind"] == "call"))},
           "nodes": sorted(nodes.values(), key=lambda n: n["id"]),
           "edges": sorted((e for e in edges.values() if e["from"] in nodes and e["to"] in nodes), key=lambda e: (e["from"], e["to"], e["kind"])),
           "timeline": timeline}
    return doc


def main():
    root, out = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    name = args[args.index("--name") + 1] if "--name" in args else os.path.basename(os.path.abspath(root))
    includes = [args[i + 1] for i, a in enumerate(args) if a == "--include"]
    excludes = {args[i + 1] for i, a in enumerate(args) if a == "--exclude"}
    also = [tuple(args[i + 1].rsplit(":", 1)) for i, a in enumerate(args) if a == "--also"]
    doc = build(root, includes, excludes, name, also)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    json.dump(doc, open(out, "w", encoding="utf8", newline="\n"), indent=1, sort_keys=True)   # LF: the same bytes on every OS
    kinds = collections.Counter(e["kind"] for e in doc["edges"])
    langs = collections.Counter(n["lang"] for n in doc["nodes"])
    print(f"{out}: {len(doc['nodes'])} blocks {dict(langs)}, edges {dict(kinds)}, {len(doc['timeline'])} entry points")


if __name__ == "__main__":
    main()
