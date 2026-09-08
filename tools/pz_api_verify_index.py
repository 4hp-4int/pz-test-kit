"""pz_api_verify_index — which indexed classes can we make ABSENCE claims about?

pz_api_check makes two kinds of claim, and they need very different evidence:

  POSITIVE  "x.hydroPowered is a public Java field"     -- the index SAYS so.
            Sound no matter how incomplete the index is: it only ever fires on
            something the index positively lists.

  ABSENCE   "props:Is() is not on PropertyContainer"    -- the index does NOT
            say so. Only sound if the index is COMPLETE for that class, and it
            provably is not everywhere: IsoLivingCharacter is missing entirely
            (so IsoPlayer's whole inherited surface reads as unknown, and
            player:getX() gets flagged), and SandboxOptions is missing 5 of its
            55 public methods including getOptionByName, which real shipping
            code calls.

So the absence check runs ONLY against classes verified here: every class in
the inheritance chain is present in the index, AND the index lists every public
method the decompiled source declares. This regenerates that allowlist.

Run it when the index is rebuilt or the game updates:
    python tools/pz_api_verify_index.py > tools/pz_api_complete.txt

Needs the decompiled source (ZomboidDecompiler output). Without it the existing
allowlist stands -- it is data, checked in, and does not need regenerating to
be used.
"""

import re
import sys
from pathlib import Path

INDEX = Path(r"C:\Users\Khalen\Code\pz-dev-tools\indexes\java-api")
SOURCE = Path(r"C:\Tools\ZomboidDecompiler\ZomboidDecompiler\bin\output\source")

RE_FQN = re.compile(r"^#\s*\w+\s*\(([\w.$]+)\)")
RE_EXT = re.compile(r"^#\s*extends\s+(\w+)")
# "  static getInstance(...)": without the optional prefix this drops every
# static method and reports the class as drifted from its own source.
RE_SIG = re.compile(r"^\s{2}(?:static\s+)?(\w+)\(")
# Public instance/static methods at class-body indentation. Deliberately strict:
# a loose pattern would match constructors and inner-class bodies and declare
# real classes incomplete, which only costs us coverage.
RE_PUB = re.compile(
    r"^\s{4}public\s+(?:static\s+|final\s+|synchronized\s+|native\s+)*"
    r"[\w.$<>\[\],\s]+\s+(\w+)\s*\(")


def load_index():
    classes = {}
    for f in sorted(INDEX.glob("*.txt")):
        fqn, ext, methods, section = None, None, set(), None
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            if fqn is None:
                m = RE_FQN.match(line)
                if m:
                    fqn = m.group(1)
                    continue
            m = RE_EXT.match(line)
            if m:
                ext = m.group(1)
                continue
            if line.startswith("## "):
                section = line[3:].strip()
                continue
            if line.startswith("  ### "):
                section = "__inner__"
                continue
            # Both sections: a closure-pulled superclass has no annotation of
            # its own, so its whole surface sits under "Other Public Methods".
            if section and (section.startswith("Lua-Exposed")
                            or section.startswith("Other Public")):
                m = RE_SIG.match(line)
                if m:
                    methods.add(m.group(1))
        classes[f.stem] = {"fqn": fqn, "extends": ext, "methods": methods}
    return classes


def main():
    if not INDEX.is_dir():
        print("# index not found at %s" % INDEX, file=sys.stderr)
        return 1
    if not SOURCE.is_dir():
        print("# decompiled source not found at %s" % SOURCE, file=sys.stderr)
        return 1

    classes = load_index()
    # Every class name the decompiler emitted, so "missing superclass" can be
    # told apart from "superclass is not PZ code".
    pz_source_stems = {p.stem for p in SOURCE.rglob("*.java")}
    verified, reasons = [], {"chain": 0, "nosource": 0, "drift": 0}

    for name, info in sorted(classes.items()):
        # 1. Every superclass must be indexed, or inherited methods look absent.
        #    EXCEPT a superclass that is not a PZ class at all: PropertyContainer
        #    extends Trove's TShortShortHashMap, and java.util/gnu.trove
        #    internals are not Lua-reachable anyway, so an external base is a
        #    clean end to the chain rather than a hole in it. "External" is
        #    decided by whether the decompiler emitted source for it, never by
        #    guessing at the name.
        chain_ok, cur, seen = True, info["extends"], set()
        while cur:
            if cur in seen:
                break
            if cur not in classes:
                if cur in pz_source_stems:
                    chain_ok = False      # a real PZ class, genuinely missing
                break                      # external base: chain ends here
            seen.add(cur)
            cur = classes[cur]["extends"]
        if not chain_ok:
            reasons["chain"] += 1
            continue

        # 2. The index must list every public method the source declares --
        #    for this class AND for everything it inherits from.
        drift = False
        missing_src = False
        for cls in [name] + [c for c in seen]:
            fqn = classes[cls]["fqn"]
            if not fqn:
                missing_src = True
                break
            src = SOURCE / (fqn.replace(".", "/") + ".java")
            if not src.exists():
                missing_src = True
                break
            pub = {m.group(1) for line in
                   src.read_text(encoding="utf-8", errors="replace").splitlines()
                   if (m := RE_PUB.match(line))}
            if pub - classes[cls]["methods"]:
                drift = True
                break
        if missing_src:
            reasons["nosource"] += 1
            continue
        if drift:
            reasons["drift"] += 1
            continue
        verified.append(name)

    print("# pz_api_complete -- classes the index is VERIFIED complete for.")
    print("# Generated by tools/pz_api_verify_index.py; do not hand-edit.")
    print("# Only these may be used for ABSENCE claims (\"no such method\").")
    print("# %d verified of %d indexed. Excluded: %d broken inheritance chain, "
          "%d no decompiled source, %d index/source drift."
          % (len(verified), len(classes), reasons["chain"], reasons["nosource"],
             reasons["drift"]))
    for name in verified:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
