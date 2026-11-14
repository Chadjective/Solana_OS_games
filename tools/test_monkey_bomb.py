#!/usr/bin/env python3
"""Plays Solana Monkey Bomb headlessly and checks it behaves.

    python3 tools/test_monkey_bomb.py

1. Full matches against the CPU (Easy and Hard), and one pass-the-badge match.
   Checks no Lua errors and every callback stays well under the badge's
   200 000-instruction limit (the CPU's planning is the heavy part).
2. A two-badge match with 20% of radio messages dropped. Checks both
   badges build the same skyline, every explosion leaves both cities
   pixel-for-pixel identical, and both agree on the final score.
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim  # noqa: E402
import test_pong_duo as net  # noqa: E402  (radio helpers)

BUDGET = 200_000


def counting(sim):
    sim.lua.execute('_COUNT = 0 debug.sethook(function() _COUNT = _COUNT + 100 end, "", 100)')


def take_count(sim):
    g = sim.lua.globals()
    n = g._COUNT
    g._COUNT = 0
    return n


def texts(sim):
    return [str(o.txt) for o in sim.M.objects.values() if o.kind == "label" and o.visible and not o.removed]


def hud_aim(sim):
    return next((t for t in texts(sim) if "angle" in t or "aiming" in t), "")


def canvas_pixels(sim):
    c = next(o for o in sim.M.objects.values() if o.kind == "canvas")
    return dict(c.buf.px)


def human_turn(sim, rnd):
    """Aim somewhere plausible with the d-pad, then throw."""
    angle_steps = rnd.randint(-10, 25)
    power_steps = rnd.randint(-5, 40)
    for _ in range(abs(angle_steps)):
        sim.press("up" if angle_steps > 0 else "down")
    for _ in range(abs(power_steps)):
        sim.press("right" if power_steps > 0 else "left")
    sim.press("select")


def play_vs_cpu(level_row, rnd, max_ticks=20000):
    sim = Sim("monkey-bomb")
    counting(sim)
    for _ in range(level_row - 1):
        sim.press("down")
    sim.press("select")
    peak, throws = 0, 0
    for _ in range(max_ticks):
        take_count(sim)
        if "UP/DN angle" in str(sim.M.hint) and "YOU:" in hud_aim(sim):
            human_turn(sim, rnd)
            throws += 1
        peak = max(peak, take_count(sim))
        sim.tick(30)
        peak = max(peak, take_count(sim))
        t = texts(sim)
        if "YOU WIN!" in t or "CPU WINS" in t:
            result = "YOU WIN!" if "YOU WIN!" in t else "CPU WINS"
            score = next(x for x in t if " - " in x)
            return result, score, throws, peak
    raise AssertionError("match never finished")


def play_hotseat(rnd, max_ticks=40000):
    sim = Sim("monkey-bomb")
    for _ in range(1):
        sim.press("down")                  # menu opens on row 1: go to row 3
    sim.press("down")
    sim.press("select")
    throws = 0
    for _ in range(max_ticks):
        if "UP/DN angle" in str(sim.M.hint) and ("P1:" in hud_aim(sim) or "P2:" in hud_aim(sim)):
            human_turn(sim, rnd)
            throws += 1
        sim.tick(30)
        t = texts(sim)
        if "P1 WINS!" in t or "P2 WINS!" in t:
            return next(x for x in t if "WINS" in x), throws
    raise AssertionError("hot-seat match never finished")


def play_duo(rnd, loss=0.2, max_ticks=60000):
    net.LOSS = loss
    stats = {"max_size": 0, "lost": 0}
    a = Sim("monkey-bomb"); a.M.badge_id = "AAAAAA"; a.name = "@alice"; a.sent = []
    b = Sim("monkey-bomb"); b.M.badge_id = "BBBBBB"; b.name = "@bob"; b.sent = []
    net.link(a, b)

    def tick(n=1):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            net.pump(a, b, stats)
            net.pump(b, a, stats)

    for s in (a, b):
        for _ in range(3):
            s.press("down")
        s.press("select")
    for _ in range(300):
        tick()
        if "@bob" in [str(i.title) for i in a.M.focus_list._items.values()]:
            break
    a.press("select")
    for _ in range(300):
        tick()
        if b.M.confirm is not None:
            break
    b.M.answer(True)
    tick(3)
    assert canvas_pixels(a) == canvas_pixels(b), "both badges must build the same skyline"

    throws, checks = 0, 0
    for _ in range(max_ticks):
        for s in (a, b):
            if "UP/DN angle" in str(s.M.hint) and "YOU:" in hud_aim(s):
                human_turn(s, rnd)
                throws += 1
        tick()
        # Between throws (both waiting for someone to aim) the cities must match.
        if ("UP/DN angle" in str(a.M.hint)) != ("UP/DN angle" in str(b.M.hint)):
            if "aiming" in hud_aim(a) or "aiming" in hud_aim(b):
                pa, pb = canvas_pixels(a), canvas_pixels(b)
                assert pa == pb, f"skylines differ after throw {throws}"
                checks += 1
        ta, tb = texts(a), texts(b)
        def won(t):
            return any(x == "YOU WIN!" or x.endswith(" WINS") for x in t)
        done_a, done_b = won(ta), won(tb)
        if done_a and done_b:
            sa = next(x for x in ta if " - " in x)
            sb = next(x for x in tb if " - " in x)
            assert sa.split()[0:3] == sb.split()[0:3], f"scores differ: {sa} / {sb}"
            title = lambda t: next(x for x in t if x == "YOU WIN!" or x.endswith(" WINS"))
            return title(ta), title(tb), sa, throws, checks, stats, a, b
    raise AssertionError("two-badge match never finished")


def main():
    rnd = random.Random(4)
    random.seed(4)
    for row, name in ((1, "Easy"), (2, "Hard")):
        result, score, throws, peak = play_vs_cpu(row, rnd)
        print(f"vs CPU {name}: {result} {score.split()[0:3]} after {throws} of your throws, "
              f"peak {peak} instructions per callback")
        assert peak < BUDGET * 0.5, "too close to the badge's instruction limit"

    winner, throws = play_hotseat(rnd)
    print(f"pass the badge: {winner} after {throws} throws")

    wa, wb, score, throws, checks, stats, a, b = play_duo(rnd)
    print(f"two badges: A sees '{wa}', B sees '{wb}', score {' '.join(score.split()[0:3])}, "
          f"{throws} throws, skylines identical at {checks} checks")
    print(f"messages: biggest {stats['max_size']} bytes, {stats['lost']} dropped on purpose, "
          f"most in one second: A {net.max_per_second(a.sent)}, B {net.max_per_second(b.sent)}")
    assert net.max_per_second(a.sent) <= 4 and net.max_per_second(b.sent) <= 4
    print("OK")


if __name__ == "__main__":
    main()
