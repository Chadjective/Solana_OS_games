#!/usr/bin/env python3
"""Copies the shared modules (shared/*.lua) into each game's folder.

    python3 tools/sync_shared.py          # copy
    python3 tools/sync_shared.py --check  # only check the copies match (exit 1 if not)

Each game ships as its own folder, so a module every game uses has to be in
every folder. Edit the copy in shared/, then run this.
"""
import filecmp
import os
import shutil
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
GAMES = ["pong", "monkey-bomb", "proof-of-stack"]
SHARED = {"scores.lua": GAMES}


def main():
    check = "--check" in sys.argv
    bad = 0
    for name, games in SHARED.items():
        src = os.path.join(ROOT, "shared", name)
        for g in games:
            dst = os.path.join(ROOT, g, name)
            same = os.path.exists(dst) and filecmp.cmp(src, dst, shallow=False)
            if check:
                if not same:
                    print(f"{g}/{name} differs from shared/{name}: run tools/sync_shared.py")
                    bad += 1
            elif not same:
                shutil.copyfile(src, dst)
                print(f"copied shared/{name} -> {g}/{name}")
    if check:
        print("shared modules: " + ("all copies match" if not bad else f"{bad} out of date"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
