import os
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 写真アプリなどの共有から、Sciaの投稿欄を開く共有拡張。拡張の中では投稿せず、受け取ったメディアをApp Groupのフォルダーに置き、
/// Sciaを開いて閉じる。投稿欄を拡張とアプリの2つに持たないため。
/// Safariのページや選んだ文は、ページのタイトルとURLと選んだ文の引用を並べた本文にして、URLでSciaに渡す。
final class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: "net.mizle.scia", category: "shareExtension")
    private var isReceiving = false

    // 受け取ってSciaを開くまで、共有シートの上に空のシートを出さないよう、透明な全画面で出してもらう。
    // 共有シートを出したアプリは、拡張の画面のmodalPresentationStyleに合わせて出す。
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 画面を出し直されても、受け取りは1回だけにする。
        guard !isReceiving else { return }
        isReceiving = true
        Task { await receive() }
    }

    private func receive() async {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "SciaURLScheme") as? String,
              let appGroup = Bundle.main.object(forInfoDictionaryKey: "SciaAppGroup") as? String,
              let inbox = SharedMediaInbox(appGroup: appGroup)
        else {
            logger.error("no url scheme or app group")
            fail()
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        logger.info("received types: \(providers.map(\.registeredTypeIdentifiers), privacy: .public)")
        if Self.isQuoteShare(providers) {
            guard let quote = await quote(from: providers) else {
                logger.error("nothing to quote")
                fail()
                return
            }
            openCompose(quote, scheme: scheme)
            return
        }
        let id = UUID()
        var count = 0
        for provider in providers {
            do {
                try await store(provider, in: inbox, id: id, index: count)
                count += 1
            } catch {
                logger.error("store failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // 受け取れなかったものがあれば、1件も受け取れなかったときも含めてSciaを開き、欠けた件数を知らせる。
        let unreadableCount = providers.count - count
        guard !providers.isEmpty, let url = URL(string: "\(scheme)://share?id=\(id.uuidString)&unreadable=\(unreadableCount)") else {
            logger.error("nothing to share")
            fail()
            return
        }
        logger.info("stored \(count, privacy: .public) of \(providers.count, privacy: .public)")
        openContainingApp(url) { [weak self] opened in
            guard opened else {
                inbox.remove(id: id)
                self?.fail()
                return
            }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Safariのページか選んだ文の共有。画像や動画が1つでも入っていれば、メディアの共有として添付する。
    private static func isQuoteShare(_ providers: [NSItemProvider]) -> Bool {
        let types = providers.flatMap(\.registeredTypeIdentifiers).compactMap { UTType($0) }
        return !types.contains { $0.conforms(to: .image) || $0.conforms(to: .movie) }
            && types.contains { $0.conforms(to: .propertyList) || $0.conforms(to: .plainText) }
    }

    /// Safariのページや選んだ文から、投稿欄の本文を作る。どれもなければnil。
    /// Safariの共有ボタンからは、前処理のJS（SharePreprocessing.js）が読んだページのタイトルとURLと選んだ文が届く。
    /// 選んだ文のメニューの「共有」からは、選んだ文がテキストで届く。
    private func quote(from providers: [NSItemProvider]) async -> String? {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) {
            let results = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any]
            let page = results?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
            return SharedQuote.body(title: page?["title"] as? String, url: page?["url"] as? String, selection: page?["selection"] as? String)
        }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else { return nil }
        // Safariは文字列で渡すが、アプリによってはUTF-8のデータで渡す。
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let url = try? await providers.first { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }?
            .loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
        return SharedQuote.body(title: nil, url: url?.absoluteString, selection: text)
    }

    private func openCompose(_ text: String, scheme: String) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "compose"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = components.url else {
            fail()
            return
        }
        openContainingApp(url) { [weak self] opened in
            guard opened else {
                self?.fail()
                return
            }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// 画像か動画の表現をファイルで受け取り、App Groupのフォルダーにコピーする。受け取ったファイルは完了の処理を抜けると消されるため、その中でコピーする。
    private func store(_ provider: NSItemProvider, in inbox: SharedMediaInbox, id: UUID, index: Int) async throws {
        let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .movie) || $0.conforms(to: .image) }
        guard let type else { throw CocoaError(.fileReadUnsupportedScheme) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try inbox.store(url, id: id, index: index)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fail() {
        extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
    }

    /// 共有拡張からアプリを開く公式のAPIはない（`NSExtensionContext.open(_:)`はウィジェットなどでしか効かない）。
    /// responder chainをたどって`UIApplication`を探し、その`open(_:options:completionHandler:)`で開く。
    /// このメソッドは拡張では使えない印が付いていてコンパイルできないため、セレクターで実装を取り出して呼ぶ。
    private func openContainingApp(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        typealias OpenURL = @convention(c) (
            UIApplication, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], (@MainActor @Sendable (Bool) -> Void)?
        ) -> Void
        var responder: UIResponder? = self
        while let current = responder, !(current is UIApplication) {
            responder = current.next
        }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let application = responder as? UIApplication, let method = class_getInstanceMethod(UIApplication.self, selector) else {
            logger.error("cannot find UIApplication.openURL:options:completionHandler:")
            completion(false)
            return
        }
        let openURL = unsafeBitCast(method_getImplementation(method), to: OpenURL.self)
        openURL(application, selector, url, [:]) { [weak self] opened in
            self?.logger.info("open containing app: \(opened, privacy: .public)")
            completion(opened)
        }
    }
}
