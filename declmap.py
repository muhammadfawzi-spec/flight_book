#!/usr/bin/env python3
"""Print top-level declarations (name + start line) of the main file."""
import re
src = open("LogMate/ContentView-2026-10-14.swift", encoding="utf-8").read().split("\n")
pat = re.compile(r"^(?:@MainActor\s+|nonisolated\s+)*(?:final\s+|private\s+)?(enum|struct|class|actor|extension)\s+([A-Za-z_][A-Za-z0-9_<]*)")
for i, ln in enumerate(src, 1):
    m = pat.match(ln)
    if m:
        print(f"{i}\t{m.group(1)} {m.group(2)}")
