import os
import SciaCore
import UIKit

/// 投稿欄でリンクにタイトルを付けるときに、本文の上に重ねる見た目。決まりはdocs/compose.mdの「リンクにタイトルを付ける」にある。
/// 選ばせる間はURLをハイライトし、読んでいる間はURLの上にきらめきを流し、置き換えるときはURLを動かしてタイトルを浮かび上がらせる。
///
/// 重ねるビューは入力欄の子にし、中身と一緒にスクロールさせる。変形の間は、本文の文字色を一時的に透明にして、本物の文字を隠す。
@MainActor
final class LinkTitleEffects {
    /// ハイライトしているURLを押した。
    var onSelect: (LinkOccurrence) -> Void = { _ in }

    private weak var textView: UITextView?
    private let tuning: TuningStore
    private let logger = SciaLog.logger(category: "compose")
    /// 選ばせているURL。幅が変わったときに、枠を並べ直すために持つ。
    private var selecting: [LinkOccurrence] = []
    /// 選ばせている間にハイライトしている枠。URLが折り返していれば、1つのURLに行の数だけある。
    private var highlights: [UIView] = []
    private var loadings: [UUID: Loading] = [:]
    private var morph: UIViewPropertyAnimator?

    private struct Loading {
        var occurrence: LinkOccurrence
        var views: [ShimmerView]
    }

    init(textView: UITextView, tuning: TuningStore) {
        self.textView = textView
        self.tuning = tuning
    }

    var isSelecting: Bool { !highlights.isEmpty }

    /// 入力欄の中の座標`point`にある、ハイライトしているURLの枠。
    func highlight(at point: CGPoint) -> UIView? {
        highlights.first { $0.isUserInteractionEnabled && $0.frame.contains(point) }
    }

    // MARK: - 選ばせる

    func beginSelecting(_ occurrences: [LinkOccurrence]) {
        endSelecting(animated: false, reason: "restart")
        selecting = occurrences
        placeHighlights(animated: !UIAccessibility.isReduceMotionEnabled)
        logger.info("compose: link title selecting (\(occurrences.count) links)")
    }

    private func placeHighlights(animated: Bool) {
        guard let textView else { return }
        for occurrence in selecting {
            for rect in rects(for: occurrence.range) {
                let view = HighlightView(frame: rect.insetBy(dx: -3, dy: -1))
                view.accessibilityLabel = occurrence.url
                view.addAction(UIAction { [weak self] _ in self?.onSelect(occurrence) }, for: .touchUpInside)
                textView.addSubview(view)
                highlights.append(view)
                view.appear(animated: animated)
            }
        }
    }

    /// - Parameter reason: ログに残す、やめたきっかけ。
    func endSelecting(animated: Bool = true, reason: String) {
        guard !highlights.isEmpty else { return }
        logger.info("compose: link title selecting ended (\(reason, privacy: .public))")
        selecting = []
        let views = highlights
        highlights = []
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            views.forEach { $0.removeFromSuperview() }
            return
        }
        views.forEach { $0.isUserInteractionEnabled = false }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            views.forEach { $0.alpha = 0 }
        } completion: { _ in
            views.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: - 読んでいる間

    /// `occurrence`の上にきらめきを流し始める。読み終えたら、返したidで`endLoading`を呼ぶ。
    func beginLoading(_ occurrence: LinkOccurrence) -> UUID {
        let id = UUID()
        loadings[id] = Loading(occurrence: occurrence, views: shimmerViews(for: occurrence))
        return id
    }

    /// きらめきを止め、読み始めてから本文が書き換えられて動いた分を含めた、そのURLの今の場所を返す。
    func endLoading(_ id: UUID) -> LinkOccurrence? {
        guard let loading = loadings.removeValue(forKey: id) else { return nil }
        loading.views.forEach { $0.disappear(duration: shimmerFadeDuration) }
        return loading.occurrence
    }

    /// きらめきを浮かび上がらせたり、薄くして消したりする時間。
    private var shimmerFadeDuration: TimeInterval {
        tuning.value(of: TuningCatalog.linkTitleShimmerFadeDuration)
    }

    private func shimmerViews(for occurrence: LinkOccurrence) -> [ShimmerView] {
        guard let textView else { return [] }
        let period = tuning.value(of: TuningCatalog.linkTitleShimmerPeriod)
        return rects(for: occurrence.range).map { rect in
            let view = ShimmerView(frame: rect.insetBy(dx: -3, dy: -1), period: period)
            textView.addSubview(view)
            return view
        }
    }

    /// 読んでいるURLのきらめきを、`occurrence`の場所へ移す。
    private func moveLoadings(_ move: (LinkOccurrence) -> LinkOccurrence?) {
        for (id, loading) in loadings {
            // 消されていたら、きらめきだけを消し、読み終えたときに置き換えるかは呼ぶ側が決める。
            guard let moved = move(loading.occurrence) else {
                loading.views.forEach { $0.disappear(duration: shimmerFadeDuration) }
                loadings[id] = Loading(occurrence: loading.occurrence, views: [])
                continue
            }
            loadings[id] = Loading(occurrence: moved, views: movedShimmers(loading.views, to: moved))
        }
    }

    /// 流れているきらめきを、`occurrence`の場所へ移す。作り直すと、流れている途中の光が1コマで消えて左端から流れ直すため、
    /// 行ごとの大きさが変わらなければ（URLの後ろや前に打ったとき）、同じビューを置き直す。
    /// 折り返しが変わって大きさが合わないときは、作り直したものを浮かび上がらせ、前のものを薄くして消す。
    private func movedShimmers(_ views: [ShimmerView], to occurrence: LinkOccurrence) -> [ShimmerView] {
        let frames = rects(for: occurrence.range).map { $0.insetBy(dx: -3, dy: -1) }
        let sameSizes = frames.count == views.count && zip(frames, views).allSatisfy { frame, view in
            abs(frame.width - view.bounds.width) < 0.5 && abs(frame.height - view.bounds.height) < 0.5
        }
        if sameSizes {
            UIView.performWithoutAnimation {
                for (view, frame) in zip(views, frames) {
                    view.frame = frame
                }
            }
            return views
        }
        views.forEach { $0.disappear(duration: shimmerFadeDuration) }
        let replacements = shimmerViews(for: occurrence)
        replacements.forEach { $0.appear(duration: shimmerFadeDuration) }
        return replacements
    }

    // MARK: - 本文や欄が変わったとき

    /// 使う人が打つなどして本文が変わった。ハイライトするのをやめ、変形をすぐ終わりの形にし、読んでいるURLのきらめきを今の場所へ移す。
    func textDidChange(_ text: String) {
        endSelecting(reason: "text")
        finishMorph()
        moveLoadings { LinkTitling.occurrence(of: $0.url, nearestTo: $0.range.lowerBound, in: text) }
    }

    /// 自分でURLを置き換えた。ほかに読んでいるURLが後ろにあれば、増えた分だけずらす。
    /// 同じURLを2か所続けて読んだとき、ずらさないと、後の結果が先に置き換えたURLをもう一度置き換えるため。
    private func didReplace(_ replacement: LinkTitleReplacement) {
        moveLoadings { $0.adjusted(afterReplacing: replacement) }
    }

    /// 欄の幅や文字の大きさが変わり、本文が折り返し直された。光る枠ときらめきを、今の文字の場所に並べ直す。
    func layoutDidChange() {
        finishMorph()
        layOutAll()
        if !highlights.isEmpty {
            highlights.forEach { $0.removeFromSuperview() }
            highlights = []
            placeHighlights(animated: false)
        }
        moveLoadings { $0 }
    }

    /// 書くのをやめた。重ねているものを片づける。読んでいる途中のものは、読み終えたときに置き換えるので残す。
    func editingDidEnd() {
        endSelecting(animated: false, reason: "editing ended")
        finishMorph()
    }

    // MARK: - 変形

    /// `replace`で本文を置き換え、置き換える前のURLを置き換えたあとの位置へ動かし、空いた場所にタイトルを浮かび上がらせる。
    /// 動きの途中で`finishMorph`が呼ばれたら、すぐ終わりの形にする。使う人が打つ前には、呼ぶ側が`finishMorph`を呼ぶ。
    func morph(_ replacement: LinkTitleReplacement, replace: @escaping () -> Void) {
        finishMorph()
        let duration = tuning.value(of: TuningCatalog.linkTitleMorphDuration)
        guard let textView, duration > 0, !UIAccessibility.isReduceMotionEnabled, textView.window != nil,
              let before = Picture(of: textView, hiding: overlayViews)
        else {
            replace()
            didReplace(replacement)
            return
        }
        // 置き換える前のURLと後ろに続く文の、行ごとの枠と文字の範囲、文字の境目の位置を測っておく。
        // 後ろの文も、URLと同じく新しい位置へ動かす。本物の文字のままだと、変形が始まった瞬間に一度に移って見えたため。
        // 動かすのは、置き換える前に見えている範囲にある文字までにする。写しは見えている範囲しか描き取れず、その外の文字は写しがないため。
        // 長い投稿で測る手間が増えすぎないよう、測るのは後ろの`maxTailLength`文字まで。それより後ろは動かさず、一度に移す。
        let oldLines = lines(of: replacement.range)
        let visible = textView.bounds
        let measuredTail = lines(of: replacement.range.upperBound ..< replacement.range.upperBound + min(textView.textStorage.length - replacement.range.upperBound, Self.maxTailLength))
        let oldTailLines = measuredTail.prefix { $0.rect.minY < visible.maxY }
        let tailLength = oldTailLines.last?.characters.upperBound ?? 0
        // 置き換えも、行が増えて欄が伸びるのも、変形と同じ時間の動きの中で行う。置き換えると、カーソルを戻すところで入力欄がその場で配置を済ませるため、
        // 置き換えてから動かすと、中身はゆっくり動くのに欄だけが急に広がって見えた。後ろに続く文も、同じ動きで新しい位置へ動く。
        // 動きを始めた時点で、欄の大きさと文字の配置は置き換えたあとの値になるので、このあとの測る処理は、置き換えたあとの形で行う。
        // 投稿欄のほかの動きと同じく`UIView.animate`で動かす。`UIViewPropertyAnimator`では、欄の枠は少しずつ伸びても、
        // Liquid Glassの形が付いてこず、1行分を一度に広げて描き直したため。動きを途中で終わらせる手段はないが、
        // 欄の大きさはもう伸びたあとの値なので、途中で打たれても、見えている動きが最後まで続くだけで、打つのは止めない。
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { [weak self] in
            replace()
            self?.layOutText()
            (textView.window ?? textView).layoutIfNeeded()
        }
        didReplace(replacement)
        let newLines = lines(of: replacement.urlRange)
        let tail = replacement.urlRange.upperBound ..< replacement.urlRange.upperBound + tailLength
        let newTailLines = lines(of: tail)
        let titleRects = rects(for: replacement.titleRange)
        // 先にURLと後ろの文を透明にしてからタイトルを描く。タイトルの行の枠に、すぐ下の行の文字の頭が入り込み、浮かび上がるタイトルの下に跡が見えたため。
        // タイトルは画面から描き取らず、文字の配置から描く。画面は欄が伸びる途中なので、描き取ると伸びる前の高さで切れたため。
        let hiddenColor = hideText(in: replacement.urlRange.lowerBound ..< tail.upperBound)
        layOutText()
        guard let after = Picture(textOf: textView, covering: rects(for: replacement.titleRange)) else {
            showText(hiddenColor)
            return
        }
        // 置き換える前と後のどちらの行の境目でも切り分け、切れ端ごとに、前の場所から後の場所へ動かす。
        // 前は1行だった文字が後で2行にまたがっても、行の外にはみ出さないようにするため。
        let pieces = Self.pieces(from: oldLines, to: newLines, picture: before) + Self.pieces(from: Array(oldTailLines), to: newTailLines, picture: before)
        let title = titleRects.map { after.view(of: $0) }
        _ = hideText(in: replacement.titleRange)
        pieces.forEach { textView.addSubview($0.view) }
        for (view, rect) in zip(title, titleRects) {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: rect.height * 0.35).scaledBy(x: 0.96, y: 0.96)
            textView.addSubview(view)
        }
        let sparkles = titleRects.map { rect in
            let view = ShimmerView(frame: rect.insetBy(dx: -3, dy: -1), period: duration, repeats: false)
            textView.addSubview(view)
            return view
        }
        logger.info("compose: link title morph (pieces=\(pieces.count) title lines=\(titleRects.count) tail=\(tailLength))")
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.85) {
            for piece in pieces {
                piece.view.frame = piece.target
            }
            for view in title {
                view.alpha = 1
                view.transform = .identity
            }
        }
        animator.isUserInteractionEnabled = true
        let fadeDuration = shimmerFadeDuration
        animator.addCompletion { [weak self] position in
            self?.logger.info("compose: link title morph ended (\(position == .end ? "end" : "other", privacy: .public))")
            self?.showText(hiddenColor)
            (pieces.map(\.view) + title).forEach { $0.removeFromSuperview() }
            sparkles.forEach { $0.disappear(duration: fadeDuration) }
            self?.morph = nil
        }
        morph = animator
        animator.startAnimation()
    }

    /// 後ろに続く文のうち、変形で動かす文字の数（UTF-16）。
    private static let maxTailLength = 300

    /// 置き換える前と後の行を、どちらの行の境目でも切り分けた切れ端。前の場所の写しと、動かす先の枠。
    private static func pieces(from oldLines: [Line], to newLines: [Line], picture: Picture) -> [(view: UIView, target: CGRect)] {
        oldLines.flatMap { old in
            newLines.compactMap { new -> (view: UIView, target: CGRect)? in
                let characters = old.characters.clamped(to: new.characters)
                guard !characters.isEmpty, let source = old.rect(of: characters), let target = new.rect(of: characters) else { return nil }
                return (picture.view(of: source), target)
            }
        }
    }

    /// 変形の途中なら、すぐ終わりの形にする。
    func finishMorph() {
        guard let morph else { return }
        logger.info("compose: link title morph finished early")
        self.morph = nil
        morph.stopAnimation(false)
        morph.finishAnimation(at: .end)
    }

    /// 本文の`range`の文字を透明にし、元の色を返す。
    /// TextKit 2の描くときだけ付ける属性（`addRenderingAttribute`）は、入力欄では描き方に効かなかったため、本文の文字色を変える。
    /// 取り消しの記録には残さない。本文の文字色はどこも同じなので、戻すときは本文全体を元の色にする。
    private func hideText(in range: Range<Int>) -> UIColor? {
        guard let textView, range.upperBound <= textView.textStorage.length else { return nil }
        let original = textView.textStorage.length > 0
            ? textView.textStorage.attribute(.foregroundColor, at: range.lowerBound, effectiveRange: nil) as? UIColor
            : nil
        let color = original ?? textView.textColor ?? .label
        withoutUndo { textView.textStorage.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(range)) }
        // 打つ文字の色は、カーソルの前の文字から決まる。透明にした文字の直後で打っても、透明にならないようにする。
        textView.typingAttributes[.foregroundColor] = color
        return color
    }

    private func showText(_ color: UIColor?) {
        guard let textView, let color else { return }
        withoutUndo { textView.textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: textView.textStorage.length)) }
        textView.typingAttributes[.foregroundColor] = color
    }

    private func withoutUndo(_ body: () -> Void) {
        let undoManager = textView?.undoManager
        undoManager?.disableUndoRegistration()
        body()
        undoManager?.enableUndoRegistration()
    }

    // MARK: - 場所

    /// 光る枠やきらめきなど、重ねているビュー。描き取るときに隠す。
    private var overlayViews: [UIView] {
        textView?.subviews.filter { $0 is HighlightView || $0 is ShimmerView || $0 is PictureView } ?? []
    }

    /// 本文の`range`（UTF-16）が描かれている、行ごとの枠。入力欄の中の座標で、スクロールした分を含む。
    private func rects(for range: Range<Int>) -> [CGRect] {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.lowerBound),
              let end = textView.position(from: textView.beginningOfDocument, offset: range.upperBound),
              let textRange = textView.textRange(from: start, to: end)
        else { return [] }
        return textView.selectionRects(for: textRange).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
    }

    /// 本文の`range`を行ごとに分けたもの。文字の範囲は`range`の頭から数える。
    /// 文字は、絵文字のようにUTF-16の2単位以上で1文字のものを途中で切らないよう、合成された文字の並びごとに測る。
    /// 改行のように枠のない文字では、行を区切る。
    private func lines(of range: Range<Int>) -> [Line] {
        guard let text = textView?.text as NSString? else { return [] }
        var lines: [Line] = []
        var lineRect: CGRect?
        var characters: [Int: CGRect] = [:]
        var lineEnd = 0
        func close() {
            guard let current = lineRect else { return }
            lines.append(Line(rect: current, characterRects: characters, end: lineEnd))
            lineRect = nil
            characters = [:]
        }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let character = text.rangeOfComposedCharacterSequence(at: offset)
            let end = min(character.location + character.length, range.upperBound)
            let rect = rects(for: offset ..< end).first
            if let current = lineRect, rect.map({ abs($0.midY - current.midY) > current.height / 2 }) ?? true {
                close()
            }
            if let rect {
                lineRect = lineRect.map { $0.union(rect) } ?? rect
                characters[offset - range.lowerBound] = rect
                lineEnd = end - range.lowerBound
            }
            offset = max(end, offset + 1)
        }
        close()
        return lines
    }

    /// 本文全体の文字の配置を済ませる。置き換えた直後は、伸びる前の欄の外に出た行が、まだ並べられていないため。
    private func layOutText() {
        guard let layoutManager = textView?.textLayoutManager else { return }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// 文字の配置に加え、本文に合わせて変わる欄の高さも含めて、画面全体の配置を済ませる。
    private func layOutAll() {
        guard let textView else { return }
        layOutText()
        (textView.window ?? textView).layoutIfNeeded()
    }
}

/// 測った範囲の1行。
private struct Line {
    let rect: CGRect
    /// この行の文字ごとの、範囲の頭から数えた位置（UTF-16）と枠。
    let characterRects: [Int: CGRect]
    /// この行の最後の文字の後ろの位置。
    let end: Int

    var characters: Range<Int> { (characterRects.keys.min() ?? end) ..< end }

    /// この行の中の`characters`の枠。文字ごとの枠を合わせて作る。右から左に書く文では、論理の順と画面の左右が逆になり、
    /// 境目の位置だけでは枠を決められないため。左右の書き方が混ざった行では、間に挟まった別の切れ端の文字まで入ることがあるが、
    /// 動いている短い間に重なって見えるだけなので、書き方ごとに分けて測る手間はかけない。
    func rect(of characters: Range<Int>) -> CGRect? {
        let rects = characterRects.filter { characters.contains($0.key) }.map(\.value)
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return CGRect(x: union.minX, y: rect.minY, width: union.width, height: rect.height)
    }
}

/// 入力欄の見えている範囲を描き取った絵。重ねたビューを隠して描く。
@MainActor
private struct Picture {
    let image: UIImage
    /// 描き取ったときの、入力欄の見えている範囲の左上。入力欄の中の座標で、スクロールした分を含む。
    let origin: CGPoint

    init?(of textView: UITextView, hiding overlays: [UIView]) {
        guard textView.bounds.width > 0, textView.bounds.height > 0 else { return nil }
        overlays.forEach { $0.isHidden = true }
        defer { overlays.forEach { $0.isHidden = false } }
        // `drawHierarchy`は、描く前に画面を更新し直し、そのときの入力欄を渡した枠に合わせて縮めて描く。
        // 置き換えた直後は、そこで欄が1行分伸び、伸びたあとの入力欄を伸びる前の高さに縮めて描いて、文字が縦につぶれた。
        // 先に配置を済ませ、それでも描いている間に大きさが変わったら、新しい大きさで描き直す。
        textView.window?.layoutIfNeeded()
        var size = textView.bounds.size
        var image = Self.draw(textView, size: size)
        if textView.bounds.size != size {
            size = textView.bounds.size
            image = Self.draw(textView, size: size)
        }
        self.image = image
        origin = textView.bounds.origin
    }

    private static func draw(_ textView: UITextView, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size)).image { _ in
            textView.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    /// 入力欄の文字の配置から、`rects`にかかる段落を描いた絵。画面に映っている途中の状態によらず、置き換えたあとの形で描く。
    init?(textOf textView: UITextView, covering rects: [CGRect]) {
        guard let layoutManager = textView.textLayoutManager, textView.bounds.width > 0, textView.bounds.height > 0 else { return nil }
        let bounds = textView.bounds
        let inset = textView.textContainerInset
        let padding = textView.textContainer.lineFragmentPadding
        image = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: bounds.size)).image { context in
            let cgContext = context.cgContext
            // 入力欄の中の座標で描く。文字の配置の座標は、入力欄の中の座標から内側の余白の分ずれている。
            cgContext.translateBy(x: -bounds.minX + inset.left + padding, y: -bounds.minY + inset.top)
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: inset.left + padding, dy: inset.top)
                if rects.contains(where: { $0.intersects(frame) }) {
                    fragment.draw(at: fragment.layoutFragmentFrame.origin, in: cgContext)
                }
                return true
            }
        }
        origin = bounds.origin
    }

    /// 入力欄の中の`rect`の部分を切り出したビュー。`rect`の場所に置く。
    func view(of rect: CGRect) -> UIView {
        PictureView(image: image, showing: rect, imageOrigin: origin)
    }
}

/// 描き取った絵の一部を見せるビュー。
private final class PictureView: UIView {
    init(image: UIImage, showing rect: CGRect, imageOrigin: CGPoint) {
        super.init(frame: rect)
        isUserInteractionEnabled = false
        clipsToBounds = true
        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: CGPoint(x: imageOrigin.x - rect.minX, y: imageOrigin.y - rect.minY), size: image.size)
        // 枠を動かしたとき、中の絵も枠と一緒に動かす。
        imageView.autoresizingMask = []
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// 選ばせている間のURLの枠。押せることが分かるよう、色合いの色で縁取って、ゆっくり明滅させる。
private final class HighlightView: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = min(6, frame.height / 2)
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HighlightView, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateColors() {
        backgroundColor = tintColor.withAlphaComponent(0.14)
        layer.borderColor = tintColor.withAlphaComponent(0.6).cgColor
        layer.shadowColor = tintColor.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    func appear(animated: Bool) {
        guard animated else { return }
        alpha = 0
        transform = CGAffineTransform(scaleX: 1.08, y: 1.2)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.alpha = 1
            self.transform = .identity
        }
        let pulse = CABasicAnimation(keyPath: "shadowRadius")
        pulse.fromValue = 3
        pulse.toValue = 9
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

/// 読んでいる間や、タイトルが浮かび上がるときに、URLやタイトルの上を流れるきらめき。
private final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()

    init(frame: CGRect, period: TimeInterval, repeats: Bool = true) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = min(6, frame.height / 2)
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        backgroundColor = tintColor.withAlphaComponent(repeats ? 0.1 : 0)
        let colors: [UIColor] = [.clear, .systemPurple, .systemPink, .systemOrange, .clear]
        gradient.colors = colors.map { $0.withAlphaComponent($0 == .clear ? 0 : 0.35).cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.frame = CGRect(x: -frame.width, y: 0, width: frame.width, height: frame.height)
        layer.addSublayer(gradient)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -frame.width / 2
        sweep.toValue = frame.width * 1.5
        sweep.duration = period
        sweep.repeatCount = repeats ? .infinity : 1
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.isRemovedOnCompletion = false
        sweep.fillMode = .forwards
        gradient.add(sweep, forKey: "sweep")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func appear(duration: TimeInterval) {
        alpha = 0
        UIView.animateSmoothly(duration: duration) {
            self.alpha = 1
        }
    }

    func disappear(duration: TimeInterval) {
        UIView.animateSmoothly(duration: duration) {
            self.alpha = 0
        } completion: {
            self.removeFromSuperview()
        }
    }
}
