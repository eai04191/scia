import SciaCore
import SwiftUI
import UIKit

/// 自動翻訳の置き換えを繰り返し見せる見本。チューニングの値は1回ごとに読み直す。
final class TranslationTransitionLoopView: UIView {
    private static let pause: TimeInterval = 1.2

    private let timeline = TimelineViewController(texts: .home, refresh: {})
    private let original: Status
    private let translated: Status
    private let contentView: PostContentView
    private var isTranslated = false
    private var timer: Timer?

    init() {
        let account = CatalogFixtures.account(displayName: "見本のアカウント", acct: "sample@example.com")
        original = Self.status(account: account, language: "zh", content: "<p>今天天气很好，我去公园散步，还买了一杯热咖啡。</p><p>这是第二段，用来确认段落的顺序。</p>")
        translated = Self.status(account: account, language: "ja", content: "<p>今日は天気がとても良かったので、公園を散歩して、帰りに温かいコーヒーを1杯買いました。風も涼しくて、とても気持ちのいい一日でした。</p><p>これは2つ目の段落で、段落の順番を確かめるための文章です。</p>")
        contentView = PostContentView(configuration: timeline.contentConfiguration(for: original, isPinned: false, base: .cell()))
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func status(account: Account, language: String, content: String) -> Status {
        Status(id: "translation-preview", createdAt: Date(timeIntervalSince1970: 0), account: account, content: content, spoilerText: "", language: language, url: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil { schedule(after: Self.pause) }
    }

    private func schedule(after delay: TimeInterval) {
        timer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(toggle), userInfo: nil, repeats: false)
    }

    @objc private func toggle() {
        isTranslated.toggle()
        var configuration = timeline.contentConfiguration(for: isTranslated ? translated : original, isPinned: false, base: .cell())
        configuration.isTranslated = isTranslated
        if isTranslated {
            configuration.body = RichTextRenderer.reservingTranslationMark(in: configuration.body, scale: 1)
        }
        contentView.configuration = configuration
        let tuning = AppDependencies.tuning
        let erasing = TextReplacementTransition.erasingEnd(
            duration: tuning.value(of: TuningCatalog.translationWipeDuration),
            fadeWidth: tuning.value(of: TuningCatalog.translationFadeWidth)
        )
        let settling = max(tuning.value(of: TuningCatalog.translationWordDuration), tuning.value(of: TuningCatalog.translationTransitionDuration))
        schedule(after: erasing + settling + Self.pause)
    }
}

struct TranslationTransitionPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> TranslationTransitionLoopView {
        TranslationTransitionLoopView()
    }

    func updateUIView(_ uiView: TranslationTransitionLoopView, context: Context) {}
}
