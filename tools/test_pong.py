#!/usr/bin/env python3
"""Plays Solana Pong headlessly against itself and checks it behaves.

    python3 tools/test_pong.py

Checks: no Lua errors, matches finish 7-x, pause/menu/exit work, and every
callback stays well under the badge's 200 000-instruction budget.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim  # noqa: E402

BUDGET = 200_000


def instrumented(sim):
    # Count VM instructions per callback with a count hook (1 hook per 100 instr).
    sim.lua.execute("""
      _COUNT = 0
      debug.sethook(function() _COUNT = _COUNT + 100 end, "", 100)
    """)


def count(sim):
    g = sim.lua.globals()
    n = g._COUNT
    g._COUNT = 0
    return n


def autopilot(sim, skill):
    """Hold up/down to follow the ball (imperfectly)."""
    g = sim.lua.globals()
    # Read the paddle and ball from the drawn objects (what a player sees).
    objs = list(sim.M.objects.values())
    pad = next(o for o in objs if o.kind == "image" and o.x == 8 and len(o.rows) == 44)
    balls = [o for o in objs if o.kind == "image" and o.visible and len(o.rows) == 16 and not o.removed]
    if not balls:
        sim.hold([])
        return
    target = balls[0].y + 8 + random.uniform(-skill, skill)
    centre = pad.y + 22
    if target < centre - 4:
        sim.hold(["up"])
    elif target > centre + 4:
        sim.hold(["down"])
    else:
        sim.hold([])


def play_match(sim, level_index, skill, max_ticks=40000):
    peak = 0
    for _ in range(3):                # menu opens on Normal: go to the top first
        sim.press("up")
    for _ in range(level_index - 1):
        sim.press("down")
    sim.press("select")
    for t in range(max_ticks):
        autopilot(sim, skill)
        count(sim)
        sim.tick(30)
        peak = max(peak, count(sim))
        msg = [o for o in sim.M.objects.values() if o.kind == "label" and o.visible and str(o.txt) in ("YOU WIN!", "CPU WINS")]
        if msg:
            scores = [str(o.txt) for o in sim.M.objects.values() if o.kind == "label" and o.opts.size == 32]
            return str(msg[0].txt), scores, t, peak
    raise AssertionError("match never finished")


def main():
    random.seed(1)
    sim = Sim("pong")
    instrumented(sim)

    for level, skill in ((1, 6), (2, 10), (3, 14)):
        result, scores, ticks, peak = play_match(sim, level, skill)
        print(f"level {level}: {result} {'-'.join(scores)} after {ticks * 30 / 1000:.0f}s, "
              f"peak {peak} instructions/tick")
        assert peak < BUDGET / 4, "too close to the instruction budget"
        assert "7" in scores
        # Play again, pause, unpause, back to menu.
        sim.press("select")
        sim.tick(30, 50)
        sim.press("select")
        assert any(str(o.txt) == "PAUSED" and o.visible for o in sim.M.objects.values() if o.kind == "label")
        sim.tick(30, 20)
        sim.press("select")
        sim.tick(30, 20)
        sim.press("back")
        sim.tick(30, 2)
        assert sim.M.focus_list is not None and not sim.M.focus_list.removed

    sim.press("back")
    assert sim.M.exited, "CANCEL on the menu should exit"
    print("wins stored:", list(sim.lua.globals().storage.get("wins").values()))
    print("OK")


if __name__ == "__main__":
    main()
