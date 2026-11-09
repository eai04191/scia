#!/usr/bin/env python3
"""Config/app-info.jsonから、アプリのAppInfo.generated.swiftとREADME.mdのマーカーの中を書き出す。

--checkを付けると書き出さず、今のファイルと違えば失敗する。
"""
import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Config/app-info.json"
SWIFT = ROOT / "App/Sources/Settings/AppInfo.generated.swift"
README = ROOT / "README.md"

ITEM_KEYS = {"name", "site", "github", "handle"}
LICENSE_KEYS = {"name", "license", "copyright", "usage", "source", "licenseURL", "app"}


def fail(message):
    sys.exit(f"error: Config/app-info.json: {message}")


def checked_url(value, where):
    parts = urlsplit(value) if isinstance(value, str) else None
    if parts is None or parts.scheme != "https" or not parts.netloc:
        fail(f"{where}のURLがhttpsのURLではありません: {value!r}")
    return value


def checked_keys(entry, allowed, required, where):
    unknown = set(entry) - allowed
    if unknown:
        fail(f"{where}に知らないキーがあります: {sorted(unknown)}")
    missing = required - set(entry)
    if missing:
        fail(f"{where}に必要なキーがありません: {sorted(missing)}")


def validate(info):
    checked_keys(info["contact"], {"email", "mastodon"}, {"email", "mastodon"}, "contact")
    if not re.fullmatch(r"[^@\s]+@[^@\s]+", info["contact"]["mastodon"]):
        fail(f"contact.mastodonがuser@domainの形ではありません: {info['contact']['mastodon']}")
    for key, url in info["links"].items():
        if not re.fullmatch(r"[a-z][A-Za-z0-9]*", key):
            fail(f"linksのキーがSwiftの名前にできません: {key}")
        checked_url(url, f"links.{key}")
    for section in info["acknowledgments"]:
        checked_keys(section, {"header", "readme", "items"}, {"header", "readme", "items"}, "acknowledgments")
        for item in section["items"]:
            checked_keys(item, ITEM_KEYS, {"name"}, f"acknowledgmentsの{item.get('name')}")
            for key in ("site", "github"):
                if key in item:
                    checked_url(item[key], f"{item['name']}の{key}")
            if "handle" in item and not re.fullmatch(r"@[^@\s]+@[^@\s]+", item["handle"]):
                fail(f"{item['name']}のhandleが@user@domainの形ではありません: {item['handle']}")
    required = {"name", "license", "copyright", "usage", "app"}
    for item in info["licenses"]:
        checked_keys(item, LICENSE_KEYS, required, f"licensesの{item.get('name')}")
        for key in ("source", "licenseURL"):
            if key in item:
                checked_url(item[key], f"{item['name']}の{key}")


def swift_string(value):
    return json.dumps(value, ensure_ascii=False)


def swift_url(value):
    return f"URL(string: {swift_string(value)})"


def swift_optional_url(value):
    return swift_url(value) if value is not None else "nil"


def swift_acknowledgment(item):
    arguments = [f"name: {swift_string(item['name'])}"]
    for key in ("site", "github"):
        if key in item:
            arguments.append(f"{key}: {swift_url(item[key])}")
    if "handle" in item:
        arguments.append(f"account: {swift_string(item['handle'].removeprefix('@'))}")
    return f"AcknowledgmentItem({', '.join(arguments)})"


def swift_license(item):
    return "\n".join([
        "        LicenseItem(",
        f"            name: {swift_string(item['name'])},",
        f"            license: {swift_string(item['license'])},",
        f"            copyright: {swift_string(item['copyright'])},",
        f"            usage: {swift_string(item['usage'])},",
        f"            source: {swift_optional_url(item.get('source'))},",
        f"            licenseURL: {swift_optional_url(item.get('licenseURL'))}",
        "        ),",
    ])


def render_swift(info):
    lines = [
        "// Config/app-info.jsonからTools/generate-app-info.pyで書き出す。直接編集しない。",
        "import Foundation",
        "",
        "enum AppInfo {",
    ]
    lines += [f"    static let {key} = {swift_url(url)}" for key, url in info["links"].items()]
    lines += [
        f"    static let contactEmail = {swift_string(info['contact']['email'])}",
        f"    static let contactMastodon = {swift_string(info['contact']['mastodon'])}",
    ]
    lines += ["", "    static let acknowledgmentSections: [AcknowledgmentSection] = ["]
    for section in info["acknowledgments"]:
        lines.append(f"        AcknowledgmentSection(header: {swift_string(section['header'])}, items: [")
        lines += [f"            {swift_acknowledgment(item)}," for item in section["items"]]
        lines.append("        ]),")
    lines += ["    ]", "", "    static let licenses: [LicenseItem] = ["]
    lines += [swift_license(item) for item in info["licenses"] if item["app"]]
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def account_url(handle):
    user, domain = handle.removeprefix("@").split("@")
    return f"https://{domain}/@{user}"


def details(summary, body):
    return f"<details>\n<summary>{html.escape(summary, quote=False)}</summary>\n\n{body}\n\n</details>"


def link_list(links):
    return "\n".join(f"- [{text}]({url})" for text, url in links)


def acknowledgment_url(item):
    """READMEは1件に1つのリンク。ウェブサイト、GitHub、アカウントの順で最初にあるものを使う。"""
    if "site" in item:
        return item["site"]
    if "github" in item:
        return item["github"]
    if "handle" in item:
        return account_url(item["handle"])
    return None


def render_acknowledgment(item):
    url = acknowledgment_url(item)
    return f"- [{item['name']}]({url})" if url else f"- {item['name']}"


def render_acknowledgments(info):
    blocks = []
    for section in info["acknowledgments"]:
        if section["readme"]:
            items = "\n".join(render_acknowledgment(item) for item in section["items"])
            blocks.append(f"{section['header']}\n\n{items}")
    return "\n\n".join(blocks)


def render_license(item):
    links = []
    if "source" in item:
        links.append(("配布元", item["source"]))
    if "licenseURL" in item:
        links.append((f"ライセンス（{item['license']}）", item["licenseURL"]))
    paragraphs = [item["copyright"], item["usage"]]
    if links:
        paragraphs.append(link_list(links))
    return details(f"{item['name']}（{item['license']}）", "\n\n".join(paragraphs))


def render_licenses(info):
    return "\n\n".join(render_license(item) for item in info["licenses"])


def replace_block(text, name, content):
    start = f"<!-- generated:{name} -->"
    end = f"<!-- /generated:{name} -->"
    pattern = re.escape(start) + r".*?" + re.escape(end)
    replaced, count = re.subn(pattern, lambda _: f"{start}\n\n{content}\n\n{end}", text, flags=re.DOTALL)
    if count != 1 or text.count(start) != 1 or text.count(end) != 1:
        sys.exit(f"error: README.mdに{start}と{end}がこの順で1つずつありません")
    return replaced


def render_readme(info, text):
    text = replace_block(text, "testflight", f"TestFlight: {info['links']['testFlight']}")
    text = replace_block(text, "acknowledgments", render_acknowledgments(info))
    return replace_block(text, "licenses", render_licenses(info))


def read_text(path):
    return path.read_text(encoding="utf-8") if path.exists() else None


def main():
    mode = sys.argv[1:]
    if mode not in ([], ["--check"]):
        sys.exit("使い方: Tools/generate-app-info.py [--check]")
    info = json.loads(SOURCE.read_text(encoding="utf-8"))
    validate(info)
    info["licenses"].sort(key=lambda item: item["name"].casefold())
    outputs = {SWIFT: render_swift(info), README: render_readme(info, README.read_text(encoding="utf-8"))}
    stale = [path for path, text in outputs.items() if read_text(path) != text]
    if mode and stale:
        names = "、".join(str(path.relative_to(ROOT)) for path in stale)
        sys.exit(f"error: {names}がConfig/app-info.jsonと違います。make app-infoで書き出してください")
    if not mode:
        for path in stale:
            path.write_text(outputs[path], encoding="utf-8")


main()
