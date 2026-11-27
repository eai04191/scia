#!/usr/bin/env python3
"""定着した用語を和語や造語に言い換えた書き方を、docs、スキル、コメント、文字列で見つけて失敗させる。

agentは、リポジトリに残っている言い方を真似て書くので、一度書き直した造語が残っていると、次の変更でまた増える。
書き直した語をここに並べ、同じ語が入ったら止める。並べた語しか見つけないので、ここにない言い換えは、
AGENTS.mdの「文言」と共通の指示の方針で判断し、見つけたらここに足す。

同じ綴りで別の意味の語（「長押し」「画像」「お知らせ」など）は、規則ごとの`allowed`に、その語を含む形で並べる。
語を挙げて決まりを説明する行（「「払う」は「スワイプ」と書く」）と、規則に当たるが残すと決めたものは、
その行に`coined-words: allow`と書く。`「」`で囲んだ語を許すと、セクション名を引いた「結果の知らせ」のような造語まで通るため。

使い方: check-coined-words.py [--at <commit>] [<パス>...]  パスを渡さなければ、Gitで追跡している対象のファイルをすべて調べる。
`--at`を渡すと、作業ツリーではなく<commit>の中身を調べる。Tools/check-stamp.shが、Markdownだけ違うcommitに前の結果を引き継ぐ前に使う。
`--self-test`で、規則が書き直した言い方を見つけ、別の意味の語を見逃すことを確かめる。
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = ['*.swift', '*.md', '*.html', '*.tsx', '*.ts', '*.js', '*.css', '*.py', '*.sh', 'Makefile', '*.yml', '*.yaml', 'Config/app-info.json', 'Tools/git-hooks/*']
# APIのfixtureは、サーバーの投稿をそのまま置いたもの
EXCLUDED_PARTS = ('/Fixtures/',)
SUPPRESS = 'coined-words: allow'


class Rule:
    def __init__(self, name, pattern, replacement, allowed=()):
        self.name = name
        self.pattern = re.compile(pattern)
        self.replacement = replacement
        self.allowed = [re.compile(a) for a in allowed]

    def find(self, line):
        spans = [m.span() for a in self.allowed for m in a.finditer(line)]
        for m in self.pattern.finditer(line):
            if not any(start <= m.start() < end for start, end in spans):
                yield m


RULES = [
    Rule('押す', r'押[すしせさそ下]', '画面の部品の操作は、docsとコメントでは選択、画面の文言とテストの文字列ではタップ。押せる・押せないは有効・無効、押せる範囲はヒット領域、押している間は押されている状態',
         allowed=[r'長押', r'押し(出|潰|縮|上げ|下げ|のけ|寄せ|込|付け|戻)', r'(もの|絵文字|入力欄)に押され', r'下へ押され', r'押されている状態',
                  r'(キー|Return|Delete|Esc|Tab|Space|Shift|Option|Command|Control|⌘)を?押', r'(何度も|続けて)押す']),
    Rule('引っぱる', r'引っぱ', 'pull to refresh、引っぱった分はオーバースクロール', allowed=[r'に引っぱられ']),
    Rule('重ねた画面', r'重ねた画面|画面を重ね|重ねて積', 'モーダルビュー、プッシュ'),
    Rule('引き出し', r'引き出し', '開閉、アクションバー'),
    Rule('まとまり', r'まとまり', 'グループ', allowed=[r'ひとまとまり']),
    Rule('すき間', r'すき間|隙間', 'gap、間隔'),
    Rule('濃さ', r'濃さ|濃く|濃淡', '不透明度、不透明度を上げる', allowed=[r'色が濃く', r'色の濃淡', r'(二重に|重なって(そこだけ)?)濃く', r'濃く見え', r'(?<!下)地を濃く', r'本文は濃く', r'タブより濃く']),
    Rule('丸み', r'丸み', 'radius、角の丸さ'),
    Rule('描き直す', r'描き直', '再描画'),
    Rule('読み直す', r'読み直|読み込み直|送り直|つなぎ直', '再読み込み、再送、再接続', allowed=[r'送る前に(自分の文を)?読み直']),
    Rule('覚える', r'覚え', '保持、記録、保存、キャッシュ', allowed=[r'違和感を覚え', r'身に覚え', r'覚えのない', r'(自分が|ために)覚えている']),
    Rule('浮かび上がる', r'浮かび上が', 'フェードイン'),
    Rule('触覚', r'触覚', 'ハプティクス'),
    Rule('字下げ', r'字下げ', 'インデント'),
    Rule('囲み', r'囲み', 'カード', allowed=[r'で囲み']),
    Rule('節', r'節', 'セクション', allowed=[r'季節', r'調節', r'関節', r'節約', r'節目']),
    Rule('窓', r'窓', 'ウィンドウ', allowed=[r'窓辺']),
    Rule('札', r'札', 'バッジ、ラベル、チケット', allowed=[r'札幌']),
    Rule('知らせ', r'(?<=の)知らせ|知らせ(?=[がをのはもにへと方先。」）（でかや]|なら|なし|まで|$)', 'チップ、アラート、コールバック、イベントなど、出すものや届くものの名前', allowed=[r'お知らせ']),
    Rule('写す', r'写[しすさせ](?!真)|写し取|描き写', 'コピー、複製、スナップショット、対応付ける', allowed=[r'書き写']),
    Rule('根', r'根(?!拠|本|気|強|底|幹|付|回し)', 'ルート', allowed=[r'垣根', r'屋根', r'大根']),
    Rule('印', r'印', 'アイコン、インジケーター、マーカー、フラグ、ハイライトなど', allowed=[r'矢印', r'目印', r'印象', r'印刷', r'刻印', r'封印', r'調印', r'押印']),
    Rule('画面の移り変わり', r'画面の移り|画面を移', '画面遷移、トランジション'),
    Rule('絵文字のシート', r'絵文字(のパレット)?の(シート|パレットのシート)|絵文字を(選ぶ|並べた)シート', '絵文字ピッカー'),
    Rule('最初の応答者', r'最初の応答者', 'ファーストレスポンダー'),
    Rule('安全領域', r'安全領域', 'セーフエリア'),
    Rule('回る表示', r'回る表示|回り続ける表示', 'アクティビティインジケーター'),
    Rule('積む', r'積[むんまみめ]', '画面はプッシュ、ナビゲーションのスタック。それ以外は挿入する、並べる、キューに入れるなど',
         allowed=[r'見積', r'面積', r'蓄積', r'累積', r'積極', r'積算', r'積み木', r'積み重', r'山積']),
    Rule('文字の大きさの設定', r'文字の大きさの設定|端末の文字の大きさ', 'Dynamic Type'),
    Rule('小さい静止画', r'小さい静止画', 'サムネイル'),
    Rule('格子', r'格子', 'グリッド（並べ方のこと）', allowed=[r'白い格子']),
    Rule('面', r'面', 'プレビュー、背景、カード、ビューなど、指すものの名前',
         allowed=[r'(画|表|場|正|側|前|背|全|平|当|断|紙|書|局|方|対|文|路|地|両|片|一|多|曲|水|内|外|仮|顔|盤|譜|帳|額|満|洗|反|直|鉄|海|月|四|二|各|誌|図|版|新|半|矢|字|球|斜|凹|凸|液|画)面', r'面(積|白|倒|談|会|目|識|接|子|持ち|食ら|と向か|取り|取る)']),
    Rule('角丸の四角', r'角丸の四角', '四角'),
    Rule('像', r'像', 'スナップショット、複製', allowed=[r'画像', r'映像', r'解像', r'想像', r'肖像', r'実像', r'虚像', r'残像', r'鏡像', r'偶像', r'仏像']),
    Rule('木', r'木', 'ツリー', allowed=[r'構文木', r'並木', r'植木', r'材木', r'樹木', r'木曜', r'木製', r'木材', r'積み木']),
    Rule('畳む', r'畳', '折りたたむ'),
    Rule('弾む', r'弾[みまむん]|ばね', 'バウンス、スプリング'),
    Rule('払う', r'払[うっわい]', 'スワイプ', allowed=[r'支払', r'振り払', r'取り払']),
    Rule('台本', r'台本', 'シナリオ'),
    Rule('覆い', r'覆い(?![、隠])', 'ぼかし', allowed=[r'覆い(直|き)']),
    Rule('鍵', r'鍵', 'キー、鍵のアイコンはロックのアイコン', allowed=[r'公開鍵', r'秘密鍵', r'合鍵', r'(VAPID|SSH)の鍵', r'<鍵>']),
    Rule('受け口', r'受け口|窓口', 'API、エンドポイント、ハンドラー'),
    Rule('種', r'(?<![各一機品業職同別人多特変亜])種(?![類別目々子])', 'seed'),
    Rule('指紋', r'指紋', 'fingerprint'),
    Rule('鍵束', r'鍵束', 'キーチェーン'),
]


def tracked_files():
    out = subprocess.run(['git', 'ls-files', '-z', '--', *PATTERNS], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    me = str(Path(__file__).resolve().relative_to(ROOT))
    return [p for p in out.split('\0') if p and p != me and not any(part in p for part in EXCLUDED_PARTS)]


def violations(text):
    for number, line in enumerate(text.split('\n'), 1):
        if SUPPRESS in line:
            continue
        for rule in RULES:
            for match in rule.find(line):
                yield number, match.start() + 1, rule, match.group(0)


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
        for line, column, rule, word in violations(text):
            failed = True
            print(f'{ROOT / path}:{line}:{column}: error: 「{word}」は造語。{rule.replacement}と書く ({rule.name})')
    return 1 if failed else 0


# 書き直した言い方（見つける）と、同じ綴りで別の意味の語（見逃す）
FLAGGED = [
    '押すと再試行する', '押下を受ける', 'ボタンを押せない', '押せる範囲', '押している間の色', '押した投稿',
    '引っぱって読み直す', '上に重ねた画面を閉じる', 'アクションバーの引き出し', '項目のまとまり', '部品のすき間',
    '透明から濃くする', '下地を濃くしている途中', '新しいビューをより濃くする', '濃さを変える', '角の丸み', '行を描き直す', '投票の結果を読み直す', '読み込み直す', '送り直す', 'つなぎ直す',
    '読んだ関係を覚えている', '投稿のIDで覚える', '下から浮かび上がらせる', '触覚フィードバック', '1段2文字で字下げする',
    '引用の囲み', '設定の節', 'その窓のアカウント', 'GIFの札', '結果の知らせ', '知らせ方', '知らせなしに消えた', '知らせが届く', '列の像', 'ビューを写し取る',
    'タブの根の画面', '再生の印', '画面の移り変わり', '画面を移る途中', '絵文字のシート', '絵文字を選ぶシート', '最初の応答者', '安全領域',
    '回る表示', 'タブに積む', '積んで開く', '画面を積む', 'その場で積む', '一番上に積む', '結果の知らせ', '「結果の知らせ」にある', '開閉の知らせ（', '押し間違えに備える', '閉じる途中に押されたら', '浮かせる面', 'ダークモードの黒い面', '下の面に落とす影', '照らされた面', '色の面', '角丸の四角', '文字の大きさの設定', '小さい静止画', '格子状', 'メニューの木', '畳む', 'わずかに弾む',
    'ばね', '下へ払う', '接続の台本', '閲覧注意の覆い', '辞書の鍵', '通知の受け口', 'ばらつかせる種', '描き写す',
]
ALLOWED = [
    '長押しする', '入力欄に押されて潰れる', '上から入ってきたものに押されて下がる', 'Returnを押す', 'キーを押す', '絵文字1つに何度も押す',
    '押し出される', '画像を開く', '映像', '想像', '解像度', '構文木', 'お知らせのリスト', 'チップで理由を知らせ、行を残す', '理由を知らせる', 'それは知らせない',
    '違和感を覚えた瞬間', '画面', '表面', '場面', '面積', '面白い', '球面線形補間', '角を面取りする', '方面', '文面', 'オレンジの地に白い格子が引かれ', '覚えのない画面', 'ひとまとまり', '下地で覆い直す', 'VAPIDの鍵', '積み重なる結合文字', '送る前に読み直す', '季節', '節約', '窓辺の猫', '札幌', '矢印', '目印', '印象', '写真', '根拠', '根本', '支払い', '公開鍵',
    '種類', '各種', '機種', '見積もり', '面積', '押されている状態', '色が濃くなる', '設定アプリのアイコンの四角と同じく地を濃くする', '選んでいるタブより濃くなる', '本文の色の濃淡で描く', '二重に濃くなる', '引数を「」で囲み',
    '「払う」は「スワイプ」と書く coined-words: allow', '並木', '数字に引っぱられる', '文字列を書き写して比べる',
]


def self_test():
    failed = False
    for text in FLAGGED:
        if not list(violations(text)):
            print(f'見つけていない: {text}')
            failed = True
    for text in ALLOWED:
        found = [(rule.name, word) for _, _, rule, word in violations(text)]
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
            print('使い方: check-coined-words.py --at <commit> [<パス>...]', file=sys.stderr)
            sys.exit(2)
        sys.exit(main(args[2:], commit=args[1]))
    sys.exit(main(args))
