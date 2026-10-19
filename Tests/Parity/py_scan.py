#!/usr/bin/env python3
"""Run the reference scanner.py on ROOT and print its results as JSON (read-only; writes nothing)."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
import scanner  # noqa: E402

root = sys.argv[1]
reference = scanner.Scanner(root, 900, 5_000_000)
tree = reference.scan(reference.root)
print(json.dumps({
    'tree': tree,
    'categories': reference.categories,
    'candidates': sorted(reference.candidates, key=lambda x: x['bytes'], reverse=True),
    'largest': [x[2] for x in sorted(reference.largest, reverse=True)],
    'stats': reference.stats,
    'errors': reference.errors,
}, ensure_ascii=False))
