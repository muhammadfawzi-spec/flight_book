#!/usr/bin/env python3
"""Verify the split is verbatim: compare the multiset of non-blank lines of the
original monolith against the union of all current Swift files, and report the
exact added/removed lines.

Usage:
    python3 tools/diffcheck.py [target_dir] [baseline_git_ref]

Defaults:
    target_dir     = LogMate
    baseline_git_ref = the pristine 24,131-line monolith in history,
                       fetched via: git show 38fb988:ContentView-2026-10-14.swift

Expected output (a faithful split) is a small, explainable delta:
  - removed: the one expression split (hoursSummary), the five de-privated
    helper declarations, and imports the monolith carried but nothing uses.
  - added: per-file `import` lines and each file's one-paragraph header comment.
Anything else (a lost or duplicated code line) is a real finding.
"""
import os
import subprocess
import sys
from collections import Counter

def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return [ln.strip() for ln in f if ln.strip()]

def baseline_lines(ref):
    # ref is like "38fb988:ContentView-2026-10-14.swift"
    out = subprocess.run(["git", "show", ref], check=True, capture_output=True, text=True)
    return [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "LogMate"
    ref = sys.argv[2] if len(sys.argv) > 2 else "38fb988:ContentView-2026-10-14.swift"

    old = Counter(baseline_lines(ref))
    new = Counter()
    for dirpath, _dirs, files in os.walk(root):
        if "Assets" in dirpath or dirpath.startswith("build"):
            continue
        for fn in files:
            if fn.endswith(".swift"):
                new.update(read_lines(os.path.join(dirpath, fn)))

    removed = old - new
    added = new - old
    print(f"== removed from {ref} (expect only the documented edits):")
    for ln, n in sorted(removed.items(), key=lambda x: (-x[1], x[0])):
        print(f"  - {n}x {ln}")
    print("== added (expect doc headers, import lines, the split expression):")
    for ln, n in sorted(added.items(), key=lambda x: (-x[1], x[0])):
        print(f"  + {n}x {ln}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
