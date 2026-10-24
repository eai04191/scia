import os
import SciaCore
import UIKit

/// 入力欄に、補完の候補と絵文字のパレットで選んだものを入れる。投稿欄とプロフィールの編集で使う。
///
/// 候補の一覧やパレットのシートをどこに置き、いつ出すかは、使う側が決める。ここでは、カーソルの位置の語を読んで補完の状態に渡すことと、
/// 選んだものを入力欄に入れることだけを受け持つ。
@MainActor
final class TextInputCompletion {
    let completion: ComposeCompletion
    /// 最近使ったカスタム絵文字。パレットの先頭に出す。なければ出さず、覚えない。
    private let recentEmojis: RecentEmojis?
    private let tuning: TuningStore
    private let settings: AppSettings
    private let logger = SciaLog.logger(category: "compose")
    /// 入力欄ごとに、補完する語の種類を返す。
    var kinds: (any UITextInput) -> Set<CompletionKind> = { _ in Set(CompletionKind.allCases) }
    /// 入力欄の文字を変えられない間（投稿を送っている間など）はtrueを返す。
    var isLocked: () -> Bool = { false }
    /// 補完やパレットで入力欄の文字を変えたあとに呼ぶ。入力欄の知らせが来なくても、持っている文字を入力欄に合わせられるようにする。
    var onApply: (any UITextInput) -> Void = { _ in }
    /// 補完している入力欄。
    private(set) weak var input: (any UITextInput)?
    private var inputHadMarkedText = false

    init(completion: ComposeCompletion, recentEmojis: RecentEmojis?, tuning: TuningStore = AppDependencies.tuning, settings: AppSettings = AppDependencies.settings) {
        self.completion = completion
        self.recentEmojis = recentEmojis
        self.tuning = tuning
        self.settings = settings
    }

    // MARK: - 補完

    /// 違和感レポートに残す、補完の状態。打った語は残さない。
    var contentSummary: String {
        switch completion.content {
        case nil: "nil"
        case .candidates(let candidates): "candidates(\(candidates.count)) selected=\(completion.selectedIndex)"
        case .loading: "loading"
        case .empty: "empty"
        case .failed: "failed"
        case .candidatesWithFailure(let candidates, _): "candidates(\(candidates.count))+failed selected=\(completion.selectedIndex)"
        }
    }

    /// 入力欄のカーソルの位置の語。
    /// - Parameter appliesMinimumLength: 候補を出すのに要る文字数を見るか。選んだときに範囲を決め直すだけなら見ず、記号だけの語も読む。
    ///   記号の直後へカーソルを戻して選んだときに語を読めないと、出したときの範囲で置き換え、カーソルより後ろのタグの文字まで消すため。
    private func token(in input: any UITextInput, appliesMinimumLength: Bool = true) -> CompletionToken? {
        guard let (text, selection) = Self.textAndSelection(of: input) else { return nil }
        let begin = input.beginningOfDocument
        let marked = input.markedTextRange.map { input.offset(from: begin, to: $0.start) ..< input.offset(from: begin, to: $0.end) }
        return CompletionTokenizer.token(
            in: text,
            selection: selection,
            markedRange: marked,
            kinds: kinds(input),
            minimumQueryLength: appliesMinimumLength ? TuningCatalog.completionMinimumQueryLength(in: tuning) : Dictionary(uniqueKeysWithValues: CompletionKind.allCases.map { ($0, 0) })
        )
    }

    func textDidChange(in input: any UITextInput) {
        self.input = input
        inputHadMarkedText = input.markedTextRange != nil
        completion.settings = TuningCatalog.completionSettings(in: tuning)
        completion.textDidChange(token(in: input))
    }

    func selectionDidChange(in input: any UITextInput) {
        guard self.input === input else { return }
        // 変換を確定しただけでは本文が変わったことにならないことがあるため、確定したらここで語を読み直す。
        if inputHadMarkedText, input.markedTextRange == nil {
            textDidChange(in: input)
            return
        }
        completion.selectionDidChange(token(in: input))
    }

    /// 入力欄の編集が終わったら閉じる。シートやビューアを出すためにキーボードを閉じたときも閉じ、戻ったら打ち直すまで出さない。
    func endEditing(in input: any UITextInput) {
        guard self.input === input else { return }
        completion.textDidChange(nil)
        self.input = nil
    }

    /// ほかの入力欄で書き始めたら、前の入力欄の補完をやめる。
    func inputDidBeginEditing(_ input: any UITextInput) {
        guard let current = self.input, current !== input else { return }
        completion.textDidChange(nil)
        self.input = nil
    }

    /// 入力欄の文字を外から入れ替えたら（投稿して空に戻したときなど）、補完していた語がなくなるので閉じる。
    func textWasReplaced(in input: any UITextInput) {
        guard self.input === input else { return }
        completion.textDidChange(nil)
    }

    /// 候補を入力欄に入れる。日本語の直後なら前に空白を、後ろに空白がなければ後ろにも空白を入れる。
    /// 入力欄の`replace`で入れ、取り消し（シェイクや⌘Z）で戻せるようにする。
    func complete(with candidate: CompletionCandidate) {
        guard let input, let shown = completion.token, !isLocked() else { return }
        // 候補を出したあとにカーソルだけを語の中で動かしていれば、置き換える範囲はいまのカーソルで決め直す。
        // ハッシュタグはカーソルより後ろを語に含めないため、出したときの範囲のままだと後ろの文まで消してしまう。
        let current = token(in: input, appliesMinimumLength: false)
        let token = current.flatMap { $0.kind == shown.kind && $0.range.lowerBound == shown.range.lowerBound ? $0 : nil } ?? shown
        let insertion = CompletionTokenizer.insertion(of: candidate.completion, replacing: token, in: Self.text(of: input))
        logger.info("completion: selected \(token.kind.rawValue, privacy: .public) leadingSpace=\(token.needsLeadingSpace)")
        guard apply(insertion, to: input) else { return }
        if case .emoji(let emoji) = candidate {
            recentEmojis?.record(emoji.shortcode)
        }
        completion.didComplete(candidate)
    }

    /// 投稿欄の＋で選んだ`@`か`#`を、カーソルの位置に入れて補完を出す。サーバーが読まない文字の直後なら、前に空白を入れる。
    func insertMark(_ kind: CompletionKind, into input: any UITextInput) {
        guard !isLocked() else { return }
        if input.markedTextRange != nil {
            input.unmarkText()
        }
        guard let (text, selection) = Self.textAndSelection(of: input) else { return }
        guard apply(CompletionTokenizer.insertion(ofMark: kind, at: selection, in: text), to: input) else { return }
        textDidChange(in: input)
    }

    /// ハードウェアキーボードで候補を選ぶ操作。
    /// - Parameters:
    ///   - isShown: 候補の一覧を出しているか。
    ///   - growsUpward: 一覧を下から積んでいるか。↑↓は見た目の向きに動かすので、下から積んでいるときは↑で優先度の低い候補へ移る。
    func keys(isShown: @escaping () -> Bool, growsUpward: @escaping () -> Bool) -> CompletionKeys {
        CompletionKeys(
            hasCandidate: { [weak self] in isShown() && self?.completion.selectedCandidate != nil },
            isShown: isShown,
            move: { [weak self] offset in self?.completion.moveSelection(by: growsUpward() ? -offset : offset) },
            confirm: { [weak self] in
                guard let self, let candidate = completion.selectedCandidate else { return }
                complete(with: candidate)
            },
            dismiss: { [weak self] in self?.completion.dismiss() }
        )
    }

    /// 補完している入力欄の、打っている行の`view`の座標での位置。
    func caretRect(in view: UIView) -> CGRect? {
        guard let input = input as? any UIView & UITextInput, let selection = input.selectedTextRange else { return nil }
        let caret = input.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return nil }
        return input.convert(caret, to: view)
    }

    // MARK: - 絵文字のパレット

    /// パレットを出すときの、最近使った絵文字。出している間に選んでも並びを変えない。押そうとしている絵文字が指の下から動かないようにするため。
    /// システムの絵文字キーボードも、閉じて開き直すまで最近使った絵文字を並べ替えない。
    var recentKeys: [String] {
        recentEmojis?.keys ?? []
    }

    /// 検索語があれば、補完と同じ順で並べた結果を出す。なければまとまりごとに並べる。
    func updatePalette(_ palette: EmojiPaletteView, recentKeys: [String]) {
        palette.cellSize = tuning.value(of: TuningCatalog.composeEmojiPaletteCellSize)
        palette.hardEdgeEffect = tuning.value(of: TuningCatalog.composeEmojiPaletteHardEdgeEffect)
        palette.barHeight = tuning.value(of: TuningCatalog.composeEmojiPaletteBarHeight)
        palette.barBottomInset = tuning.value(of: TuningCatalog.composeEmojiPaletteBarBottomInset)
        palette.animatesEmojis = settings.animatesCustomEmojis
        palette.emojiStyle = settings.emojiStyle
        let query = palette.query
        let standardGroups = StandardEmojiAvailability.groups(for: settings.emojiStyle)
        // カスタム絵文字の一覧がまだないか読めなかったときも、Unicodeの絵文字は通信なしで並べられるので出し、カスタム絵文字の場所に状態を出す。
        let emojis = completion.emojis ?? []
        let customStatus: EmojiPaletteView.CustomEmojiStatus? = if completion.emojis != nil {
            nil
        } else if let message = completion.emojiFailureMessage {
            .failed(message)
        } else {
            .loading
        }
        if query.isEmpty {
            let recentLimit = Int(tuning.value(of: TuningCatalog.composeEmojiPaletteRecentLimit))
            palette.setContent(.sections(EmojiPalette.sections(emojis: emojis, standardGroups: standardGroups, recentKeys: recentKeys, recentLimit: recentLimit), customStatus: customStatus))
        } else {
            palette.setContent(.searchResults(EmojiPalette.searchResults(matching: query, emojis: emojis, standardGroups: standardGroups, limit: 200), customStatus: customStatus))
        }
    }

    /// パレットで選んだ絵文字を入力欄に入れる。
    func insert(_ emoji: PaletteEmoji, into input: any UITextInput) {
        guard !isLocked() else { return }
        if input.markedTextRange != nil {
            input.unmarkText()
        }
        guard let (text, selection) = Self.textAndSelection(of: input) else { return }
        let insertion = switch emoji {
        case .custom(let custom):
            CompletionTokenizer.insertion(of: ":\(custom.shortcode):", at: selection, in: text)
        case .standard(let standard):
            // Unicodeの絵文字は文字そのものなので、サーバーが読むための空白は要らない。選んでいる範囲と置き換える。
            CompletionInsertion(range: selection, text: standard.emoji, cursor: selection.lowerBound + standard.emoji.utf16.count)
        }
        guard apply(insertion, to: input) else { return }
        recentEmojis?.record(emoji.recentKey)
    }

    /// パレットの削除のボタン。カーソルの直前が絵文字なら、絵文字をまとめて消す。範囲を選んでいればそれを、それ以外は1文字消す。
    func deleteBackward(in input: any UITextInput) {
        guard !isLocked() else { return }
        guard let (text, selection) = Self.textAndSelection(of: input) else { return }
        // パレットを出している間は入力欄がフォーカスを持たないので、`deleteBackward`に頼らず、消す範囲を求めて置き換える。
        let range: Range<Int>
        if let emoji = CompletionTokenizer.emojiDeletionRange(before: selection, in: text) {
            range = emoji
        } else if !selection.isEmpty {
            range = selection
        } else {
            let before = String(decoding: Array(text.utf16).prefix(selection.lowerBound), as: UTF16.self)
            guard let last = before.last else { return }
            range = selection.lowerBound - String(last).utf16.count ..< selection.lowerBound
        }
        apply(CompletionInsertion(range: range, text: "", cursor: range.lowerBound), to: input)
    }

    // MARK: - 入力欄

    /// 範囲を置き換え、カーソルを置き、使う側に知らせる。範囲が入力欄の外なら何もせずfalseを返す。
    @discardableResult
    private func apply(_ insertion: CompletionInsertion, to input: any UITextInput) -> Bool {
        let begin = input.beginningOfDocument
        guard let start = input.position(from: begin, offset: insertion.range.lowerBound),
              let end = input.position(from: begin, offset: insertion.range.upperBound),
              let range = input.textRange(from: start, to: end)
        else { return false }
        input.replace(range, withText: insertion.text)
        if let cursor = input.position(from: begin, offset: insertion.cursor) {
            input.selectedTextRange = input.textRange(from: cursor, to: cursor)
        }
        onApply(input)
        return true
    }

    private static func text(of input: any UITextInput) -> String {
        (input as? UITextView)?.text ?? (input as? UITextField)?.text ?? ""
    }

    /// 入力欄の今の文字と、選んでいる範囲（UTF-16）。
    private static func textAndSelection(of input: any UITextInput) -> (String, Range<Int>)? {
        guard let selection = input.selectedTextRange else { return nil }
        let begin = input.beginningOfDocument
        let start = input.offset(from: begin, to: selection.start)
        let end = input.offset(from: begin, to: selection.end)
        return (text(of: input), start ..< max(start, end))
    }
}
