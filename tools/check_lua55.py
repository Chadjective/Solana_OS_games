#!/usr/bin/env python3
"""Checks the Lua files for things Lua 5.5 (the badge's Lua) refuses but
Lua 5.4 (what the tools here run) accepts:

  * assigning to a `for` loop's variable inside the loop (read-only in 5.5)
  * using `global` as a name (a keyword in 5.5)

    python3 tools/check_lua55.py
"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def strip(src):
    # drop comments and string contents, keep line structure
    src = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    src = re.sub(r'"(\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"'(\\.|[^'\\\n])*'", "''", src)
    return src


def check(path):
    problems = []
    lines = strip(open(path).read()).split("\n")
    depth = 0
    loops = []          # (names, depth inside the loop, line)
    for no, line in enumerate(lines, 1):
        if re.search(r"\bglobal\b", line):
            problems.append(f"{path}:{no}: 'global' is a keyword in Lua 5.5")
        # Open any loop this line starts first, so `for i = 1, 3 do i = 2 end`
        # on one line is caught too; its header itself isn't an assignment.
        body = line
        for tok in re.findall(r"\b(for|do|then|if|elseif|function|repeat|end|until|while)\b", line):
            if tok == "for":
                m = re.match(r"\s*.*?\bfor\s+([\w\s,]+?)\s*(=|\bin\b)", line)
                if m:
                    loops.append(([x.strip() for x in m.group(1).split(",")], depth + 1, no))
                    after = re.search(r"\bdo\b(.*)$", line)
                    body = after.group(1) if after else ""
        for names, d, start in loops:
            for n in names:
                for m in re.finditer(r"(?<![\w.:])" + re.escape(n) + r"\s*(,[\w\s,.\[\]]*)?=(?!=)", body):
                    before = body[:m.start()]
                    if re.search(r"\b(local|for)\s+[\w\s,]*$", before):
                        continue      # a new local or a new loop, not an assignment
                    if before.count("{") > before.count("}"):
                        continue      # a table field, not the variable
                    problems.append(f"{path}:{no}: assigns to loop variable '{n}' (loop at line {start})")
        for tok in re.findall(r"\b(for|do|then|if|elseif|function|repeat|end|until|while)\b", line):
            if tok in ("do", "function", "repeat", "if"):
                depth += 1
            elif tok in ("end", "until"):
                depth -= 1
                loops = [l for l in loops if l[1] <= depth]
    return problems


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "*", "*.lua")))
    problems = [p for f in files for p in check(f)]
    for p in problems:
        print(os.path.relpath(p, ROOT) if os.path.exists(p.split(":")[0]) else p)
    print(f"checked {len(files)} files: {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
