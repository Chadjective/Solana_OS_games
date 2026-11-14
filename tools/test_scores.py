#!/usr/bin/env python3
"""Checks the nearby leaderboards (shared/scores.lua) in all three games.

    python3 tools/test_scores.py

Two simulated badges with saved best scores sit on their menus; A opens its
leaderboard. Checks: A lists B's bests and its own, best first (lower first
for times), LEFT/RIGHT switches category, a badge with no score in a
category is left out, B shows "here now" and then "earlier" once it's out of
range, the list is saved and comes back after a restart, and the shared
copies of scores.lua all match.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sim import Sim  # noqa: E402
import test_pong_duo as net  # noqa: E402

GAMES = [
    # app, A's storage, B's storage, presses down to reach "Nearby leaderboard",
    # then per category the rows A should show: (name, score text)
    ("pong", {"wins": [1, 2, 3], "duo_wins": 1}, {"wins": [0, 0, 9], "duo_wins": 0}, 3,
     [[("@bob", "9"), ("YOU", "6")], [("YOU", "1")]]),
    ("monkey-bomb", {"best_points": 1200, "match_wins": [1, 0, 2]}, {"best_points": 3400, "match_wins": [0, 0, 0]}, 4,
     [[("@bob", "3,400"), ("YOU", "1,200")], [("YOU", "3")]]),
    ("proof-of-stack", {"best": {"lamports": 50000, "sprint": 95000, "wins": 2},
                        "day": 20771, "daily": {"day": 20771, "best": 7000}},
     {"best": {"lamports": 120000, "sprint": 81000, "wins": 0},
      "day": 20771, "daily": {"day": 20771, "best": 9000}}, 4,
     [[("@bob", "120,000"), ("YOU", "50,000")], [("@bob", "1:21.0"), ("YOU", "1:35.0")], [("YOU", "2")],
      [("@bob", "9,000"), ("YOU", "7,000")]]),
]


def to_py(v):
    if hasattr(v, "items"):
        return {k: to_py(x) for k, x in v.items()}
    return v


def rows(sim):
    lst = next(o for o in sim.M.objects.values() if o.kind == "list" and not o.removed)
    out = []
    for it in lst._items.values():
        name = str(it.title).split(". ", 1)[1]
        out.append((name, str(it.right), str(it.sub)))
    return out


def check_game(app, store_a, store_b, downs, expected):
    a = Sim(app, store_a, "AAAAAA", "@alice")
    b = Sim(app, store_b, "BBBBBB", "@bob")
    a.sent, b.sent = [], []
    net.link(a, b)
    net.LOSS = 0.0
    stats = {"max_size": 0, "lost": 0}

    def tick(n, linked=True):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            if linked:
                net.pump(a, b, stats)
                net.pump(b, a, stats)
            else:                       # B out of range: drop everything
                a.M.outbox = a.lua.table_from([])
                b.M.outbox = b.lua.table_from([])

    tick(250)                           # ~7.5 s on the menus: a couple of announcements each way
    for _ in range(downs):
        a.press("down")
    a.press("select")
    tick(1)
    assert any("NEARBY LEADERBOARD" == str(o.txt) for o in a.M.objects.values()
               if o.kind == "label" and not o.removed), "leaderboard didn't open"
    for i, want in enumerate(expected):
        got = rows(a)
        assert [(n, s) for n, s, _ in got] == want, f"{app} category {i + 1}: {got} != {want}"
        a.press("right")
    a.press("right") if len(expected) == 1 else None
    # back on category 1 (pressed RIGHT once per category); B is here now
    b_row = next(r for r in rows(a) if r[0] == "@bob")
    assert b_row[2] == "here now", b_row

    # B walks away: after 15 s without hearing it, it's "earlier".
    tick(600, linked=False)
    a.press("right")
    for _ in range(len(expected) - 1):
        a.press("right")
    b_row = next(r for r in rows(a) if r[0] == "@bob")
    assert b_row[2] == "earlier", b_row

    # CANCEL goes back to the menu.
    a.press("back")
    tick(1)
    assert str(a.M.hint).startswith("SELECT play"), a.M.hint

    # A restart remembers B (saved in storage).
    saved = to_py(a.M.store["nearby"])
    assert "BBBBBB" in saved and saved["BBBBBB"]["n"] == "@bob", saved
    a2 = Sim(app, {**store_a, "nearby": saved}, "AAAAAA", "@alice")
    for _ in range(downs):
        a2.press("down")
    a2.press("select")
    a2.tick(30)
    assert [(n, s) for n, s, _ in rows(a2)] == expected[0], rows(a2)
    assert next(r for r in rows(a2) if r[0] == "@bob")[2] == "earlier"
    print(f"{app}: leaderboard shows {expected[0]} ... ({len(expected)} categories), "
          f"'here now' -> 'earlier', remembered after a restart; "
          f"radio at most {max(net.max_per_second(a.sent), net.max_per_second(b.sent))} a second")
    assert net.max_per_second(a.sent) <= 4 and net.max_per_second(b.sent) <= 4


def daily_other_day():
    """A badge still on yesterday's daily challenge doesn't show in today's list."""
    a = Sim("proof-of-stack", {"day": 20771, "daily": {"day": 20771, "best": 7000}}, "AAAAAA", "@alice")
    b = Sim("proof-of-stack", {"day": 20770, "daily": {"day": 20770, "best": 9000},
                               "best": {"lamports": 500, "sprint": 0, "wins": 0}}, "BBBBBB", "@bob")
    a.sent, b.sent = [], []
    net.link(a, b)
    net.LOSS = 0.0
    stats = {"max_size": 0, "lost": 0}
    for _ in range(250):
        a.tick(30)
        b.tick(30)
        net.pump(a, b, stats)
        net.pump(b, a, stats)
    for _ in range(4):
        a.press("down")
    a.press("select")
    a.tick(30)
    assert [r[:2] for r in rows(a)] == [("@bob", "500")], rows(a)       # B is heard...
    for _ in range(3):
        a.press("right")
    assert [r[:2] for r in rows(a)] == [("YOU", "7,000")], rows(a)      # ...but not in today's daily
    print("proof-of-stack: yesterday's daily score is left out of today's daily list")


def main():
    random.seed(1)
    r = subprocess.run([sys.executable, os.path.join(HERE, "sync_shared.py"), "--check"])
    assert r.returncode == 0, "shared copies differ"
    for g in GAMES:
        check_game(*g)
    daily_other_day()
    print("OK")


if __name__ == "__main__":
    main()
