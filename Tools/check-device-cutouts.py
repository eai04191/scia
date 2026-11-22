#!/usr/bin/env python3
"""入っているXcodeのシミュレーターのiPhoneのうち、ステータスバーの通知の機種の表にないものを見つけて失敗させる。

ステータスバーの通知は、アイランドとノッチの位置を機種の識別子で引く（App/Sources/Notices/StatusBarTickerView.swiftの
`IslandModel.table`、`NotchModel.table`、`DeviceModel.flatIdentifiers`）。表にない機種では通知が出ない。
新しいiPhoneの入ったXcodeに上げたときに、測り忘れに気づくための検査。

対象は、入っているiOSのランタイムのうち、Sciaの最低対応OS（project.ymlのdeploymentTarget）以降のものが動かせるiPhone。機種の定義の識別子（modelIdentifierとrepresentedModelIdentifiers）の
どれかが表にあれば測ってあるとみなす。表に入れない機種は、理由を付けてEXCLUDEDに書く。
"""

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE_SOURCE = ROOT / 'App/Sources/Notices/StatusBarTickerView.swift'
PROJECT = ROOT / 'project.yml'
DEPLOYMENT_TARGET = re.compile(r'^  deploymentTarget:\n    iOS: "([0-9.]+)"', re.MULTILINE)

# 表に入れない機種と、その理由。
EXCLUDED = {
    # 画面の横にステータスバーとアイランドが縦に並ぶ（HIGの「iPhone Duo向けのデザイン」の垂直コントロール）。
    # 上端に横に流す今の通知の形が合わないので、測って表に足すのではなく、通知の形から考える。
    'iPhone19,4': 'iPhone Duo',
}

TABLE_ENTRY = re.compile(r'^\s*"(iPhone\d+,\d+)":', re.MULTILINE)
FLAT_SET = re.compile(r'static let flatIdentifiers: Set<String> = \[([^\]]*)\]')
IDENTIFIER = re.compile(r'"(iPhone\d+,\d+)"')


def known_identifiers(source: str) -> set[str]:
    known = set(TABLE_ENTRY.findall(source))
    flat = FLAT_SET.search(source)
    if not flat:
        raise SystemExit(f'{TABLE_SOURCE}: flatIdentifiersが見つからない')
    known |= set(IDENTIFIER.findall(flat.group(1)))
    if not known:
        raise SystemExit(f'{TABLE_SOURCE}: 機種の表が見つからない')
    return known


def simctl_json(*args: str) -> dict:
    return json.loads(subprocess.run(['xcrun', 'simctl', 'list', *args, '-j'], check=True, capture_output=True, text=True).stdout)


def version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split('.'))


def deployment_target() -> tuple[int, ...]:
    match = DEPLOYMENT_TARGET.search(PROJECT.read_text())
    if not match:
        raise SystemExit(f'{PROJECT}: iOSのdeploymentTargetが見つからない')
    return version(match.group(1))


def installed_iphones(minimum: tuple[int, ...]) -> dict[str, list[str]]:
    """入っているiOSのランタイムのうち、`minimum`以降のものが動かせるiPhoneの、名前と識別子。"""
    iphones: dict[str, list[str]] = {}
    for runtime in simctl_json('runtimes')['runtimes']:
        if runtime.get('platform') != 'iOS' or not runtime.get('isAvailable', True) or version(runtime['version']) < minimum:
            continue
        for device_type in runtime.get('supportedDeviceTypes', []):
            if device_type.get('productFamily') != 'iPhone' or device_type['name'] in iphones:
                continue
            profile = Path(device_type['bundlePath']) / 'Contents/Resources/profile.plist'
            with profile.open('rb') as file:
                info = plistlib.load(file)
            iphones[device_type['name']] = [info['modelIdentifier'], *info.get('representedModelIdentifiers', [])]
    if not iphones:
        raise SystemExit('Sciaの最低対応OS以降のiOSのシミュレーターのランタイムが入っていない')
    return iphones


def main() -> int:
    known = known_identifiers(TABLE_SOURCE.read_text())
    missing = [
        (name, identifiers)
        for name, identifiers in sorted(installed_iphones(deployment_target()).items())
        if not any(identifier in known or identifier in EXCLUDED for identifier in identifiers)
    ]
    for name, identifiers in missing:
        print(f'{TABLE_SOURCE}: error: ステータスバーの通知の機種の表に{name}（{", ".join(sorted(set(identifiers)))}）がない。'
              'アイランドかノッチを測って表に足すか、切り欠きがなければflatIdentifiersに、表に入れないならTools/check-device-cutouts.pyのEXCLUDEDに足す')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
