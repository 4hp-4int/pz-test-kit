#!/usr/bin/env python3
"""Analyze a PZ dedicated server cmd log for TooltipLib readObject traffic.

WHY THIS EXISTS
---------------
TooltipLib 1.6.1 (68f7795) claims to cut MP readObject traffic with a
hover-dwell gate. Its baseline came from this exact log (GameServer.java:2275
writes every client command through LoggerManager.getLogger("cmd")):

    41,714 readObject commands over ~100 min, 4 players
    97.5% of all logged command volume
    63% arriving within 250ms of the previous one   <- the sweep flood
    13% genuine 2s-TTL refreshes

The gate is CLIENT side, so whatever reaches this log is traffic the gate did
not stop. The <250ms share is the verdict: that bucket is objects the cursor
swept past while walking, which should now never leave the client.

WHY NOT A LUA LISTENER: measured 2026-08-09, an Events.OnClientCommand listener
registered through pz-shell eval on a live 42.20.2 dedi never receives client
commands at all (it gets called with a single incrementing integer instead).
The Java dispatch and this log are both fine. Instrument from the log.

Gaps are computed PER PLAYER. Pooling several cursors invents short intervals
no single player produced.

Usage:
    python analyze_cmd_log.py <path-to-cmd.txt> [--since HH:MM]
"""

import re
import sys
from collections import defaultdict, Counter
from datetime import datetime

LINE = re.compile(
    r"^\[(?P<ts>[\d-]+ [\d:.]+)\]\s+\S+\s+\"(?P<user>[^\"]+)\"\s+"
    r"(?P<mod>[A-Za-z0-9_]+)\.(?P<cmd>[A-Za-z0-9_]+)\s+@"
)
# PZ writes day-month-year, two digits each.
TS_FMT = "%d-%m-%y %H:%M:%S.%f"


def parse(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LINE.match(line.strip())
            if not m:
                continue
            try:
                ts = datetime.strptime(m.group("ts"), TS_FMT)
            except ValueError:
                continue
            rows.append((ts, m.group("user"), m.group("mod"), m.group("cmd")))
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]

    since = None
    if "--since" in sys.argv:
        since = sys.argv[sys.argv.index("--since") + 1]

    rows = parse(path)
    if not rows:
        print("No parseable command lines. Wrong file, or the server logged nothing.")
        return 1

    if since:
        hh, mm = (int(x) for x in since.split(":"))
        rows = [r for r in rows if (r[0].hour, r[0].minute) >= (hh, mm)]
        if not rows:
            print(f"No lines at or after {since}.")
            return 1

    span_min = (rows[-1][0] - rows[0][0]).total_seconds() / 60.0
    print("=== PZ cmd log: TooltipLib readObject analysis ===")
    print(f"file:   {path}")
    print(f"window: {rows[0][0]:%H:%M:%S} -> {rows[-1][0]:%H:%M:%S}  ({span_min:.1f} min)")
    print(f"lines:  {len(rows)}")

    mix = Counter(f"{m}.{c}" for _, _, m, c in rows)
    print("\ncommand volume:")
    for key, n in mix.most_common(12):
        print(f"  {key:<44} {n:6d}  ({100.0 * n / len(rows):5.1f}%)")

    ro = [r for r in rows if r[2] == "TooltipLib" and r[3] == "readObject"]
    if not ro:
        print("\nNo readObject at all. That is NO EVIDENCE about the gate, not")
        print("evidence it works — nobody hovered a world object in this window.")
        return 0

    share = 100.0 * len(ro) / len(rows)

    # Per player, because an interval is only meaningful within one cursor.
    by_user = defaultdict(list)
    for ts, user, _, _ in ro:
        by_user[user].append(ts)

    gaps = []
    print("\nreadObject per player:")
    for user, stamps in sorted(by_user.items()):
        stamps.sort()
        per = [
            (stamps[i] - stamps[i - 1]).total_seconds() * 1000.0
            for i in range(1, len(stamps))
        ]
        gaps.extend(per)
        rate = len(stamps) / span_min if span_min > 0 else 0
        print(f"  {user:<24} {len(stamps):6d}  ({rate:.1f}/min)")

    buckets = [
        ("<250ms",     lambda g: g < 250,            "SWEEP FLOOD - baseline 63%"),
        ("250-500",    lambda g: 250 <= g < 500,     ""),
        ("500-1500",   lambda g: 500 <= g < 1500,    "below the 1500ms cooldown"),
        ("1500-2500",  lambda g: 1500 <= g < 2500,   "around the 2s cache TTL"),
        (">=2500",     lambda g: g >= 2500,          ""),
    ]
    print(f"\ninter-arrival, per player ({len(gaps)} intervals):")
    flood = 0.0
    for label, pred, note in buckets:
        n = sum(1 for g in gaps if pred(g))
        pctv = 100.0 * n / len(gaps) if gaps else 0.0
        if label == "<250ms":
            flood = pctv
        suffix = f"   <- {note}" if note else ""
        print(f"  {label:<11}{n:6d}  ({pctv:5.1f}%){suffix}")

    print(f"\nreadObject share of all commands: {share:.1f}%   (baseline 97.5%)")
    print(f"rate: {len(ro) / max(span_min * max(len(by_user), 1), 0.01):.1f} "
          f"readObject/player-minute")

    print()
    if flood < 20:
        print(f"VERDICT: sweep flood {flood:.1f}% vs 63% baseline — the gate is working.")
    elif flood < 45:
        print(f"VERDICT: partial. {flood:.1f}% vs 63% baseline.")
    else:
        print(f"VERDICT: flood still dominant at {flood:.1f}%. Check the CLIENT's")
        print("TooltipLib version — a Steam-subscribed v1.6.0 (the last pre-fix")
        print("release) outranks Zomboid\\mods without -modfolders.")

    if len(ro) < 200:
        print()
        print(f"SAMPLE CAVEAT: only {len(ro)} readObject commands. The baseline had")
        print("41,714. Percentages are directionally useful but noisy; a longer")
        print("session of deliberate cursor-sweeping would firm this up.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
