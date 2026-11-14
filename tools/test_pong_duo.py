#!/usr/bin/env python3
"""Plays a two-badge Solana Pong match between two simulated badges.

    python3 tools/test_pong_duo.py

The simulated radio delays each message by one tick and drops a share of
them at random, like the real mesh. Checks: the badges find each other,
the invite works, every message fits in 200 bytes, no badge sends more than
4 messages in any second, both badges agree on the score at the end, and
their two views of the ball stay mirror images of each other.
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim  # noqa: E402
from test_pong import autopilot  # noqa: E402

LOSS = 0.15
W, BALL_W = 320, 20


def to_py(v):
    if hasattr(v, "items"):
        d = {k: to_py(x) for k, x in v.items()}
        return d
    return v


def make(badge_id, name):
    s = Sim("pong")
    s.M.badge_id = badge_id
    s.name = name
    s.sent = []        # times of messages sent, for the rate check
    return s


def link(a, b):
    a.M.peers = a.lua.table_from([a.lua.table_from({"id": b.M.badge_id, "name": b.name, "kind": "badge", "bridged": False})])
    b.M.peers = b.lua.table_from([b.lua.table_from({"id": a.M.badge_id, "name": a.name, "kind": "badge", "bridged": False})])


def pump(src, dst, stats):
    out = list(src.M.outbox.values())
    src.M.outbox = src.lua.table_from([])
    for item in out:
        msg = to_py(item.msg)
        size = len(json.dumps(msg, separators=(",", ":")))
        stats["max_size"] = max(stats["max_size"], size)
        assert size <= 200, f"message too big ({size} bytes): {msg}"
        src.sent.append(int(item.at))
        if item.to not in ("*", dst.M.badge_id):
            continue
        if random.random() < LOSS:
            stats["lost"] += 1
            continue
        dst.M.deliver(src.M.badge_id, dst.lua.table_from(msg))


def max_per_second(times):
    worst = 0
    j = 0
    for i, t in enumerate(times):
        while times[j] <= t - 1000:
            j += 1
        worst = max(worst, i - j + 1)
    return worst


def ball(s):
    for o in s.M.objects.values():
        if o.kind == "image" and o.visible and not o.removed and len(o.rows) == 16:
            return o
    return None


def labels(s, size):
    return [str(o.txt) for o in s.M.objects.values() if o.kind == "label" and o.opts.size == size]


def visible_text(s):
    return [str(o.txt) for o in s.M.objects.values() if o.kind == "label" and o.visible and not o.removed]


def main():
    random.seed(7)
    stats = {"max_size": 0, "lost": 0}
    a, b = make("AAAAAA", "@alice"), make("BBBBBB", "@bob")
    link(a, b)

    def tick(n=1):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            pump(a, b, stats)
            pump(b, a, stats)

    # Both open "2 players: 2 badges" (menu starts on Normal, row 2 -> row 4).
    for s in (a, b):
        s.press("down")
        s.press("down")
        s.press("select")
    for _ in range(300):                  # "hello" messages repeat until heard
        tick()
        if "@bob" in [str(i.title) for i in a.M.focus_list._items.values()]:
            break
    assert "@bob" in [str(i.title) for i in a.M.focus_list._items.values()], "A should see B in the lobby"
    a.press("select")                     # invite B
    for _ in range(100):
        tick()
        if b.M.confirm is not None:
            break
    assert b.M.confirm is not None, "B should be asked"
    print("B is asked:", b.M.confirm.text)
    b.M.answer(True)
    tick(5)

    mismatch, samples = 0.0, 0
    for t in range(60000):
        autopilot(a, 34)
        autopilot(b, 34)
        tick()
        ba, bb = ball(a), ball(b)
        if ba is not None and bb is not None:
            # Mirror images of each other (except while one waits at a paddle).
            d = abs(ba.x - (W - bb.x - BALL_W)) + abs(ba.y - bb.y)
            samples += 1
            mismatch += min(d, 40)
        over_a = any(x in ("YOU WIN!", "@bob WINS") for x in visible_text(a))
        over_b = any(x in ("YOU WIN!", "@alice WINS") for x in visible_text(b))
        if over_a and over_b:
            break
    else:
        raise AssertionError("match never finished")

    sa, sb = labels(a, 32), labels(b, 32)
    print(f"finished after {t * 30 / 1000:.0f}s: A sees {sa}, B sees {sb}")
    print("A:", [x for x in visible_text(a) if "WIN" in x], " B:", [x for x in visible_text(b) if "WIN" in x])
    assert sa == list(reversed(sb)), "both badges must agree on the score"
    print(f"average ball mismatch between the two screens: {mismatch / samples:.1f} px")
    print(f"messages: biggest {stats['max_size']} bytes, {stats['lost']} dropped on purpose, "
          f"most in one second: A {max_per_second(a.sent)}, B {max_per_second(b.sent)}")
    assert max_per_second(a.sent) <= 4 and max_per_second(b.sent) <= 4
    assert mismatch / samples < 3

    # Quitting tells the other badge.
    a.press("select"); b.press("select")      # both back to the lobby
    tick(80)
    a.press("select")
    for _ in range(100):
        tick()
        if b.M.confirm is not None:
            break
    b.M.answer(True)
    tick(100)
    a.press("back")
    tick(5)
    assert "PLAYER LEFT" in visible_text(b), visible_text(b)
    print("quit message reaches the other badge: OK")
    print("OK")


if __name__ == "__main__":
    main()
