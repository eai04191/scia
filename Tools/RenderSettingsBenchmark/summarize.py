#!/usr/bin/env python3
"""RENDER_BENCHの各9回の計測から中央値と範囲を出す。"""
from pathlib import Path
import json
import re
import statistics
import sys

pattern = re.compile(r'RENDER_BENCH layout=(true|false) sample=(\d+) rows=(\d+) ms=([\d.]+)')
text = Path(sys.argv[1]).read_text()
if not re.search(r'\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*', text) or re.search(r'\*\* TEST (?:EXECUTE )?(?:FAILED|INTERRUPTED) \*\*', text):
    raise SystemExit('xcodebuildが成功した計測ログではありません。')
if not re.search(r'Test measureRows\(layout:\).* passed after', text):
    raise SystemExit('計測テストの成功がありません。')
results = {}
for layout, sample, rows, elapsed in pattern.findall(text):
    key = (layout, int(sample))
    if key in results:
        raise SystemExit(f'重複した計測: {key}')
    if int(rows) != 500:
        raise SystemExit('行数が500ではありません。')
    results[key] = float(elapsed)
expected = {(layout, sample) for layout in ['false', 'true'] for sample in range(9)}
if results.keys() != expected:
    raise SystemExit('計測は各モードのsample=0〜8が必要です。')
summary = {}
for layout in ['false', 'true']:
    elapsed = [results[(layout, sample)] for sample in range(9)]
    summary['configuration_and_layout' if layout == 'true' else 'configuration'] = {
        'rows_per_sample': 500,
        'samples': 9,
        'median_ms': statistics.median(elapsed),
        'range_ms': [min(elapsed), max(elapsed)],
    }
print(json.dumps(summary, indent=2))
