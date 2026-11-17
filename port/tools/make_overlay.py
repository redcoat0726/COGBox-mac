#!/usr/bin/env python3
"""Reconstruct the SDK header overlay from COGBox's SDK patch.

COGBox's renderer talks to a rexglue SDK that is not the released one: their
`patches/rexglue-sdk.diff` adds six new files to the SDK (draw_observer,
frame_hooks, the trace protocol/writer) and modifies ~50 existing ones. The six
new files can be materialised from the diff's creation hunks, which is enough
for 17 translation units to compile against the stock release SDK. The ~50
modified files cannot be worked around this way - those need an SDK built from
source.

This overlay is therefore a stopgap for compiling, not a substitute for the real
thing. It is generated rather than committed because it is rexglue SDK source
code (BSD-3-Clause), and vendoring it into this repository would redistribute
someone else's tree.

    python3 tools/make_overlay.py            # writes ./sdk-overlay
    python3 tools/make_overlay.py --check    # verify what is on disk is current
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
DIFF = os.path.join(PORT, "..", "Gears2-Native", "patches", "rexglue-sdk.diff")
OUT = os.path.join(PORT, "sdk-overlay")


def parse(path):
    """[(old_name, new_name, hunk_lines)] for every file section of a unified diff."""
    sections, section = [], None
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("--- "):
                section = [line[4:], "", []]
                sections.append(section)
            elif line.startswith("+++ ") and section is not None and not section[1]:
                section[1] = line[4:]
            elif section is not None:
                section[2].append(line)
    return sections


def created_files():
    """{path: content} for the files the diff creates from nothing."""
    out = {}
    for old, new, lines in parse(DIFF):
        if not old.strip().endswith("/dev/null"):
            continue
        name = new[2:] if new.startswith("b/") else new
        body = [line[1:] for line in lines if line.startswith("+") and not line.startswith("+++")]
        out[name] = "\n".join(body) + "\n"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report drift instead of writing")
    args = ap.parse_args()

    if not os.path.exists(DIFF):
        sys.exit(f"make_overlay: {DIFF} not found - Gears2-Native is incomplete (this repo's fork tree)")

    files = created_files()
    if not files:
        sys.exit("make_overlay: the diff creates no files; has it changed shape?")

    drift = 0
    for name, content in sorted(files.items()):
        dst = os.path.join(OUT, name)
        current = None
        if os.path.exists(dst):
            with open(dst, encoding="utf-8", errors="surrogateescape") as f:
                current = f.read()
        if args.check:
            state = "ok" if current == content else ("missing" if current is None else "stale")
            if state != "ok":
                drift += 1
            print(f"  {state:8s} {name}")
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  wrote    {name}  ({content.count(chr(10))} lines)")

    if args.check:
        print(f"\n{len(files) - drift}/{len(files)} current" + ("" if drift == 0 else f", {drift} need regenerating"))
        return 1 if drift else 0
    print(f"\n{len(files)} files in {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
