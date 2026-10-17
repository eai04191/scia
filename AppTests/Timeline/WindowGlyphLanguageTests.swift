import SciaCore
import SwiftUI
import Testing
import UIKit
@testable import Scia

/// 文字列に言語がないと、システムは端末の言語の一覧から漢字とかなの書体を選び、英語の設定では中国語の書体で描かれていた。
/// アプリの文言は、アプリが表示している言語の字形で描く。人が書いた言語の分からない文字は、設定の「漢字の字形」で描く。
/// 英語の設定（`-testLanguage en`）でも通す。
@MainActor
struct WindowGlyphLanguageTests {
    private let text = "直骨関ホーム"
    private let font = UIFont.systemFont(ofSize: 40)

    private func settings(_ glyphLanguage: GlyphLanguage) throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "WindowGlyphLanguageTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.glyphLanguage = glyphLanguage
        return settings
    }

    private func window() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        return window
    }

    private func label(language: String? = nil) -> UILabel {
        let label = UILabel()
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        attributes[.languageIdentifier] = language
        label.attributedText = NSAttributedString(string: text, attributes: attributes)
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        return label
    }

    private func render(_ view: UIView) -> Data {
        view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds).pngData { view.layer.render(in: $0.cgContext) }
    }

    /// 言語を付けた文字列を描いた結果と比べ、どの言語の書体で描かれたかを確かめる。書体の名前は、ラベルの描画からは取り出せないため。
    private func reference(_ language: String) -> Data {
        render(label(language: language))
    }

    private var appLanguage: String {
        Bundle.main.preferredLocalizations.first ?? ""
    }

    @Test func appTextUsesAppLanguage() throws {
        let window = try window()
        window.useAppLanguage()
        let label = label()
        window.addSubview(label)

        #expect(appLanguage == "ja")
        #expect(render(label) == reference("ja"))
        #expect(render(label) != reference("zh-Hans"))
    }

    /// 中国語の投稿のように文字列に言語が付いていれば、ウィンドウの言語よりそちらを優先する。
    @Test func attributedLanguageWinsOverWindow() throws {
        let window = try window()
        window.useAppLanguage()
        let label = label(language: "zh-Hans")
        window.addSubview(label)

        #expect(render(label) == reference("zh-Hans"))
    }

    /// UIKitのビューの書体を選ぶ言語は、言語の部分しか保たない。繁体字を選んでも簡体字の書体になるため、人の文字には文字列で言語を付ける。
    @Test func viewTraitDropsScript() throws {
        let window = try window()
        let label = label()
        label.traitOverrides.typesettingLanguage = Locale.Language(identifier: "zh-Hant")
        window.addSubview(label)

        #expect(render(label) == reference("zh-Hans"))
        #expect(reference("zh-Hans") != reference("zh-Hant"))
    }

    /// 人の文字の入力欄は、打った文字にも置いた文字にも設定の字形の言語を付け、選び直すと付け直す。
    @Test func textViewLabelsTextWithSettingLanguage() async throws {
        let settings = try settings(.traditionalChinese)
        let textView = GlyphLanguageTextView()
        #expect(textView.textStorage.delegate == nil)
        textView.followGlyphLanguage(of: settings)
        textView.text = "直骨"
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.insertText("関")
        // かな漢字変換の途中の文字も、確定した文字も、変わらずに入る。
        textView.setMarkedText("ちょく", selectedRange: NSRange(location: 3, length: 0))
        textView.setMarkedText("直", selectedRange: NSRange(location: 1, length: 0))
        textView.unmarkText()

        #expect(textView.text == "直骨関直")
        #expect(languages(of: textView) == ["zh-Hant"])

        settings.glyphLanguage = .japanese
        await Task.yield()

        #expect(languages(of: textView) == ["ja"])
    }

    private func languages(of textView: UITextView) -> Set<String?> {
        var result = Set<String?>()
        let storage = textView.textStorage
        storage.enumerateAttribute(.languageIdentifier, in: NSRange(location: 0, length: storage.length)) { value, _, _ in result.insert(value as? String) }
        return result
    }

    /// UIHostingControllerの中のSwiftUIの文言にも届く。
    @Test func swiftUIUsesAppLanguage() throws {
        let window = try window()
        window.useAppLanguage()
        window.isHidden = false
        func hosted(_ view: some View) -> Data {
            let host = UIHostingController(rootView: view.font(.system(size: 40)).frame(width: 300, height: 60, alignment: .leading))
            window.rootViewController = host
            host.view.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
            host.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }
        let plain = hosted(Text(text))
        let japanese = hosted(Text(text).typesettingLanguage(.init(identifier: "ja")))
        let chinese = hosted(Text(text).typesettingLanguage(.init(identifier: "zh-Hans")))

        #expect(plain == japanese)
        #expect(plain != chinese)
    }

    /// アプリのウィンドウは、設定の字形にかかわらず、アプリが表示している言語で描く。
    @Test func sceneWindowUsesAppLanguage() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try #require(scene.windows.first { $0 is ShakeDetectingWindow })

        #expect(window.traitCollection.typesettingLanguage == Locale.Language(identifier: appLanguage))
    }

    /// 投稿欄の入力は、設定の字形で描く。
    @Test func inlineComposeLabelsTypedText() throws {
        let window = try window()
        let host = UITabBarController(tabs: [UITab(title: "ホーム", image: nil, identifier: "home") { _ in UIViewController() }])
        window.rootViewController = host
        let composer = InlineComposeController(model: ComposeModel(myAccountID: "1") { _ in }, tuning: TuningStore(defaults: nil), settings: try settings(.traditionalChinese))
        composer.install(in: host)
        let textView = try #require(host.view.descendants(of: UITextView.self).first { $0.accessibilityLabel == "本文" })
        textView.insertText("直骨")

        #expect(languages(of: textView) == ["zh-Hant"])
    }

    /// 代替テキストの入力と全文は、設定の字形で描く。
    @Test func altTextUsesSettingLanguage() throws {
        let editor = AltTextEditorView(settings: try settings(.traditionalChinese))
        editor.textView.insertText("直骨")
        #expect(languages(of: editor.textView) == ["zh-Hant"])

        let controller = AltTextViewController(text: "代替", settings: try settings(.traditionalChinese))
        controller.loadViewIfNeeded()
        let textView = try #require(controller.view.descendants(of: UITextView.self).first)
        #expect(languages(of: textView) == ["zh-Hant"])
    }

    /// ビューアの下の代替テキストは設定の字形で、書き始めを促す文言はアプリの言語で描く。
    @Test func captionSeparatesTextAndPlaceholder() throws {
        let caption = CaptionView(settings: try settings(.traditionalChinese))
        let label = try #require(caption.descendants(of: UILabel.self).first)
        caption.text = "代替"
        #expect(label.attributedText?.attribute(.languageIdentifier, at: 0, effectiveRange: nil) as? String == "zh-Hant")

        caption.text = ""
        caption.isEditable = true
        #expect(label.text == "代替テキストを追加")
        #expect(label.attributedText?.attribute(.languageIdentifier, at: 0, effectiveRange: nil) == nil)
    }
}

extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}
