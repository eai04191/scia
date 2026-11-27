#!/usr/bin/env python3
"""文の頭の短い主題（「成功は、」「Sciaでは、」）のすぐあとの読点を、Markdownで見つけて失敗させる。

agentはリポジトリに残っている書き方を真似て書くので、間を作るだけの読点が残っていると、次の変更でまた増える。
外しても読み方が変わらない形だけを拾い、次の読点は残す。
- 読点のあと12字の中に別の主語や主題（「〜が」「〜は」）が来るもの。外すと前の主題が後ろの動詞の主語に読めるため
- 同じ文の中で、同じ助詞の主題を読点で並べたもの（「Aは、〜、Bは、〜」）
- 空白を除いて13字以上の主題と、中に別の主語がある主題
- 8字以上の条件や場面の枠（「添付を選んだときは、」）
- 指示語だけの主題（「これは、」）と、引用、かっこ、コードの中
規則に当たるが残すと決めた行には、`pause-comma: allow`と書く。

使い方: check-pause-comma.py [--at <commit>] [<パス>...]  パスを渡さなければ、Gitで追跡しているMarkdownをすべて調べる。
`--at`を渡すと、作業ツリーではなく<commit>の中身を調べる。Tools/check-stamp.shが、Markdownだけ違うcommitに前の結果を引き継ぐ前に使う。
`--self-test`で、拾う形を拾い、残す形を見逃すことを確かめる。
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = ['*.md']
EXCLUDED_PARTS = ('/Fixtures/',)
SUPPRESS = 'pause-comma: allow'

PARTICLES = ('では', 'には', 'とは', 'は', 'も')
MAX_TOPIC = 12
MAX_FRAME = 7
NEAR_SUBJECT = 12
QUOTES = {'「': '」', '『': '』', '“': '”', '（': '）', '(': ')', '`': '`', '[': ']'}
SENTENCE_END = '。！？!?'
# 句の頭に来る記号（箇条書き、見出し、引用、チェックボックス、強調）
LEAD = re.compile(r'^(?:\s*(?:[-*+]|\d+[.)])\s+|\s*#+\s+|\s*>\s*)?(?:\[[ xX]\]\s+)?(?:\*\*|__)?')
DEMONSTRATIVE = re.compile(r'^(?:それ|これ|あれ|そこ|ここ|こちら|そちら|どれ|どこ)$')
FRAME = re.compile(r'(?:場合|とき|時|際|あと|後|うち|ため|前|間|限り|以上|以降|以前|直後|直前|途中|最中|なら|たら|れば)(?:に|で)?$')
# 句の中の主語や主題（「〜が」「〜は」）
CLAUSE = re.compile(r'[^、]が|[^でにとて]は(?!$)')
TE_FORM = re.compile(r'[てで]$')


def mask(line):
    """引用、かっこ、コードの中身を〇に置き換える。かっこそのものは残し、位置を変えない。"""
    out = []
    stack = []
    for ch in line:
        if stack and ch == stack[-1]:
            stack.pop()
            out.append(ch)
            continue
        if ch in QUOTES and not (ch == '`' and stack and stack[-1] != '`'):
            out.append(ch)
            stack.append(QUOTES[ch])
            continue
        out.append('〇' if stack else ch)
    return ''.join(out)


def sentences(text):
    start = 0
    for i, ch in enumerate(text):
        if ch in SENTENCE_END:
            yield start, text[start:i + 1]
            start = i + 1
    if start < len(text):
        yield start, text[start:]


def next_subject(after):
    """読点のあとNEAR_SUBJECT字の中に、別の主語「Xが」か主題「Xは」があるか。"""
    window = after[:NEAR_SUBJECT]
    for m in re.finditer(r'[がは]', window):
        before = window[:m.start()]
        if not before or before[-1] in '、をにへとのやかでてもだ':
            continue
        if m.group(0) == 'が' and re.search(r'[たるいだす]$', before):
            continue  # 逆接の「が」（使えるが、）
        return True
    return False


def hits(line):
    plain = mask(line)
    lead = LEAD.match(plain).end()
    for offset, sentence in sentences(plain[lead:]):
        base = lead + offset
        body = sentence.lstrip(' 　*')
        base += len(sentence) - len(body)
        comma = body.find('、')
        if comma <= 0:
            continue
        topic = body[:comma].rstrip('*_')
        particle = next((p for p in PARTICLES if topic.endswith(p)), None)
        if particle is None:
            continue
        head = topic[:-len(particle)]
        if not head.strip():
            continue
        length = len(re.sub(r'\s', '', topic))
        if length > MAX_TOPIC + len(particle):
            continue
        if DEMONSTRATIVE.match(head) or TE_FORM.search(head) and particle in ('は', 'も'):
            continue
        if FRAME.search(head) and length > MAX_FRAME:
            continue
        if CLAUSE.search(head):
            continue
        rest = body[comma + 1:]
        if next_subject(rest):
            continue
        if re.search(r'[^\s、。]' + re.escape(particle) + '、', rest):
            continue
        if particle == 'も' and (re.search(r'[^最]も(?!の)', head) or re.search(r'[^\s、。最]も(?!の)', rest.split('、')[0])):
            continue
        # 外すと同じ字がつながる（「は、はじめに」）
        if rest[:1] == particle[-1]:
            continue
        yield base + comma - len(particle) + 1, line[base:base + comma + 1]


def tracked_files():
    out = subprocess.run(['git', 'ls-files', '-z', '--', *PATTERNS], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [p for p in out.split('\0') if p and not any(part in p for part in EXCLUDED_PARTS)]


FENCE = re.compile(r'^\s*(`{3,}|~{3,})')


def mask_comments(line, in_comment):
    """HTMLコメントの中を〇に置き換え、行の終わりでまだコメントの中かを返す。"""
    out = []
    i = 0
    while i < len(line):
        if in_comment:
            end = line.find('-->', i)
            stop = len(line) if end < 0 else end + 3
            out.append('〇' * (stop - i))
            i = stop
            in_comment = end < 0
        else:
            start = line.find('<!--', i)
            if start < 0:
                out.append(line[i:])
                break
            out.append(line[i:start])
            i = start
            in_comment = True
    return ''.join(out), in_comment


def violations(text):
    fence = None
    in_comment = False
    for number, line in enumerate(text.split('\n'), 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line[m.end():].strip():
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        visible, in_comment = mask_comments(line, in_comment)
        if SUPPRESS in line:
            continue
        for column, topic in hits(visible):
            yield number, column, topic


def read(path, commit):
    if commit is None:
        return (ROOT / path).read_text(encoding='utf-8')
    return subprocess.run(['git', 'show', f'{commit}:{path}'], cwd=ROOT, capture_output=True, check=True).stdout.decode('utf-8')


def main(paths, commit=None):
    failed = False
    for path in paths or tracked_files():
        try:
            text = read(path, commit)
        except (OSError, UnicodeDecodeError, subprocess.CalledProcessError) as error:
            print(f'{path}: error: 読めない: {error}', file=sys.stderr)
            return 2
        for line, column, topic in violations(text):
            failed = True
            print(f'{ROOT / path}:{line}:{column}: error: 「{topic.strip()}」の読点は間を作るだけなので外す。残すなら行に{SUPPRESS}と書く')
    return 1 if failed else 0


# 拾う形と、残す形
FLAGGED = [
    '成功は、画面の変化で見えないときだけ知らせる。',
    '- 失敗の原因は、リリース版の記録だけで絞れるようにする',
    'Sciaは、投稿、予約、編集をJSONで送る。',
    'Mastodonでは、投稿に付いた添付の代替テキストを、編集で変える。',
    '確認日は、リンク先のソースを読んだ日である。',
    '消えたアプリ内通知の失敗も、あとから確かめられるようにする',
    'そのときは、閉じる。',
    '**Sciaは**、JSONで送る。',
    '投稿を送った。Sciaは、返った投稿を読む。',
    'Sciaは、Mastodon歴8年の作者が使うために作るアプリである。',
    'Holloは、v2の`a`もv1の`b`も返さない。',
    'Aは、一覧に出す。Bは、出さない。',
    'Sciaは、使えるが、遅い。',
    '`max_id`は、古い側の端を指す。',
    '成功は、知らせる。<!-- 下書き\n続き -->',
]
ALLOWED = [
    'Aは、一覧に出し、Bは、出さない。',
    'これは、決まりである。',
    'ドラッグで閉じる操作の途中で離したときは、元に戻す。',
    '一覧に`application/octet-stream`があれば、形式を絞らない。',
    '`Sciaは、`のような書き方',
    '「成功は、」の読点',
    '使っては、いけない。',
    '一覧を読む人が多いアプリの名前は、短くする。',
    'Sciaは結果を出す。',
    'ほかの実装は、Mastodonが返す形と違う。',
    'AもBも、同じ形で送る。',
    'は、はじめに出す。',
    '成功は、画面の変化で見えないときだけ知らせる。 pause-comma: allow',
    '<!-- 成功は、画面で知らせる。 -->',
    '~~~\n成功は、知らせる。\n~~~',
    '````\n```\n成功は、知らせる。\n```\n````',
]


def self_test():
    failed = False
    for text in FLAGGED:
        if not list(violations(text)):
            print(f'見つけていない: {text}')
            failed = True
    for text in ALLOWED:
        found = [topic for _, _, topic in violations(text)]
        if found:
            print(f'止めている: {text} {found}')
            failed = True
    print('self-test ' + ('失敗' if failed else 'OK'))
    return 1 if failed else 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        sys.exit(self_test())
    args = sys.argv[1:]
    if args[:1] == ['--at']:
        if len(args) < 2:
            print('使い方: check-pause-comma.py --at <commit> [<パス>...]', file=sys.stderr)
            sys.exit(2)
        sys.exit(main(args[2:], commit=args[1]))
    sys.exit(main(args))
