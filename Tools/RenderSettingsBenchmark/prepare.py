#!/usr/bin/env python3
"""手動計測用のテストをAppTestsへ配置する。アプリのソースやGit履歴は読まない。"""
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[2]
destination = root / 'AppTests' / 'RenderSettingsBenchmarkGenerated'
name = 'RenderSettingsBenchmarkTests.swift'
if sys.argv[1:] == ['clean']:
    # 以前の比較用builderも、このツールが生成したファイルなので削除する。
    for generated in [name, 'BaselinePostContentBuilder.swift', 'SnapshotPostContentBuilder.swift']:
        (destination / generated).unlink(missing_ok=True)
    if destination.exists():
        destination.rmdir()
    sys.exit(0)
if sys.argv[1:]:
    raise SystemExit('usage: prepare.py [clean]')
if destination.exists():
    raise SystemExit('生成先が存在します。先にcleanしてください。')
destination.mkdir()
shutil.copyfile(Path(__file__).parent / name, destination / name)
