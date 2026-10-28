#if DEBUG
import SciaCore
import UIKit

/// 投稿欄の投票の欄（`ComposePollEditor`）の状態。投稿欄の中に置いたときのフォーカスやキーボードとの重なりは、実物の投稿欄で確かめる。
enum ComposePollEditorCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        let longOption = String(repeating: "選択肢の文字が長いときの切れ方", count: 3)
        return [
            state("足した直後（選択肢2つ、空）", PollDraft()),
            state("書いた選択肢（最後の欄に書いたので、空の欄が増えた）", PollDraft(options: ["犬", "猫", ""])),
            state("選択肢が上限の4つ（空の欄を足さない）", PollDraft(options: ["朝", "昼", "夜", "深夜"])),
            state("途中の欄を空にした", PollDraft(options: ["朝", "", "夜", ""])),
            state("複数選ぶ、結果を隠す、締め切り7日", PollDraft(options: ["朝", "昼", ""], multiple: true, hidesTotals: true, expiresIn: 604_800)),
            state("選択肢の文字が長い", PollDraft(options: [longOption, "短い"])),
            state("締め切りの選択肢をサーバーの上限で絞る（10分から1日、メニューで確かめる）", PollDraft(options: ["", ""], expiresIn: 1_800), limits: PollLimits(maxOptions: 4, maxCharactersPerOption: 50, expirationRange: 600...86_400)),
            state("狭い幅（結果のボタンを縮める）", PollDraft(options: ["朝", "昼", ""], hidesTotals: true), width: 300),
            state("もっと狭い幅（選び方のボタンも縮める）", PollDraft(options: ["朝", "昼", ""], multiple: true, expiresIn: 1_800), width: 285),
            state("縮めても収まらない幅（行末をぼかして切る）", PollDraft(options: ["朝", "昼", ""], multiple: true, expiresIn: 1_800), width: 262),
            state("折りたたんだ（小さい画面で本文を書いている）", PollDraft(options: ["朝", "昼", "夜", "深夜"], multiple: true), folded: true),
            state("折りたたんだ、選択肢をまだ書いていない", PollDraft(), folded: true),
            state("折りたたんだ、選択肢の文字が長い", PollDraft(options: [longOption, "短い"]), folded: true),
        ]
    }

    @MainActor
    private static func state(_ title: String, _ poll: PollDraft, limits: PollLimits = .mastodonDefault, folded: Bool = false, width: CGFloat? = nil) -> CatalogState {
        CatalogState(title: title) {
            let editor = ComposePollEditor()
            editor.onMakeField = { field in
                field.followGlyphLanguage(of: AppDependencies.settings)
            }
            editor.apply(ComposePollEditor.Content(
                poll: poll,
                expiryChoices: PollDraft.expiryChoices(within: limits)
            ))
            editor.setFolded(folded)
            // 投稿欄と同じく、左右に余白を取った板の上に置く。
            let frame = UIView()
            frame.backgroundColor = .secondarySystemBackground
            editor.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(editor)
            NSLayoutConstraint.activate([
                editor.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
                editor.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -4),
                editor.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16),
                width == nil
                    ? editor.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -10)
                    : editor.trailingAnchor.constraint(lessThanOrEqualTo: frame.trailingAnchor, constant: -10),
            ])
            // 投稿欄の幅より狭い画面や大きな文字で、設定の行の文言を縮めたところを、どの端末でも見られるよう幅を決める。
            if let width {
                editor.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            return CatalogFrame.bordered(frame)
        }
    }
}
#endif
