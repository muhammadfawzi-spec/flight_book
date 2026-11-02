#!/usr/bin/env python3
"""Show top-level type declarations and their line numbers across a directory.

Usage:
    python3 tools/declmap.py [path]      # default path: LogMate

Prints one line per top-level declaration as:
    <file>:<line>  <kind> <Name>
"""
import os
import re
import sys

pat = re.compile(
    r"^(?:@MainActor\s+|nonisolated\s+|private\s+|fileprivate\s+)*"
    r"(?:final\s+)?(enum|struct|class|actor|extension)\s+([A-Za-z_][A-Za-z0-9_<]*)"
)

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "LogMate"
    if not os.path.isdir(root):
        print(f"not a directory: {root}", file=sys.stderr)
        return 1
    entries = []
    for dirpath, _dirnames, files in os.walk(root):
        if "Assets" in dirpath or dirpath.startswith("build"):
            continue
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, encoding="utf-8") as f:
                for i, ln in enumerate(f, 1):
                    m = pat.match(ln)
                    if m:
                        rel = p.replace(root, "", 1).lstrip("/")
                        entries.append((rel, i, f"{m.group(1)} {m.group(2)}"))
    for rel, i, name in entries:
        print(f"{rel}:{i}  {name}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
