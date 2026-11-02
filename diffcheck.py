#!/usr/bin/env python3
"""Verify the split is verbatim: multiset of non-blank lines of
old files vs new files, reporting the exact added/removed lines."""
import os, sys
from collections import Counter

BASE = sys.argv[1] if len(sys.argv) > 1 else "LogMate"
old = Counter(
    ln.strip() for ln in open("/private/var/folders/cp/29s94x0s7c71s6_qytw80tf00000gn/T/opencode/lmmate/baseline.swift", encoding="utf-8")
    if ln.strip()
)
new = Counter()
for root, dirs, files in os.walk(BASE):
    if "Assets" in root or ".build" in root or root.startswith("build"):
        continue
    for fn in files:
        if fn.endswith(".swift"):
            path = os.path.join(root, fn)
            for ln in open(path, encoding="utf-8"):
                if ln.strip():
                    new[ln.strip()] += 1

removed = old - new   # in old, missing from new
added = new - old     # in new, not in old
print("== removed from original (expected: only the two documented edits):")
for ln, n in removed.items():
    print(f"  - {n}x {ln}")
print("== added (expected: doc headers, imports, restructured line, de-privated helpers):")
for ln, n in sorted(added.items()):
    print(f"  + {n}x {ln}")
