#!/usr/bin/env python3
"""Checks the "How to play" pages (shared/help.lua + each game's howto.lua).

    python3 tools/test_help.py

For each game: "How to play" is the last menu entry, every page opens and
LEFT/RIGHT turns through them all (and back round), every line fits (at most
11 lines a page and 40 characters a line: the badge's small text is a
fixed-width font), and CANCEL goes back to the menu.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sim import Sim  # noqa: E402

GAMES = ["pong", "monkey-bomb", "proof-of-stack"]


def visible(sim):
    return [str(o.txt) for o in sim.M.objects.values() if o.kind == "label" and o.visible and not o.removed]


def main():
    for g in GAMES:
        sim = Sim(g)
        items = [str(i.title) for i in sim.M.focus_list._items.values()]
        assert items[-1] == "How to play", items
        for _ in range(len(items)):
            sim.press("down")
        sim.press("select")
        sim.tick(30)
        first = visible(sim)
        n = int(first[1].split("/")[1])
        titles = []
        for page in range(n):
            t = visible(sim)
            titles.append(t[0])
            assert t[1] == f"{page + 1}/{n}", t[:2]
            lines = t[2:]
            assert len(lines) <= 11, (g, t[0], len(lines))
            too_long = [x for x in lines if len(x) > 40]
            assert not too_long, (g, t[0], too_long)
            sim.press("right")
        assert visible(sim)[0] == titles[0], "RIGHT on the last page goes back to the first"
        sim.press("left")
        assert visible(sim)[0] == titles[-1], "LEFT on the first page goes to the last"
        sim.press("back")
        sim.tick(30)
        assert str(sim.M.hint).startswith("SELECT play"), sim.M.hint
        print(f"{g}: How to play has {n} pages ({', '.join(titles)}); all lines fit; CANCEL returns to the menu")
    print("OK")


if __name__ == "__main__":
    main()
