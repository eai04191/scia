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
        if SharedQuote.isQuote(typeIdentifiers: providers.flatMap(\.registeredTypeIdentifiers)) {
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
                logger.error("store failed: \(SciaLog.describe(error), privacy: .public)")
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

    /// Safariのページや選んだ文やリンクから、投稿欄の本文を作る。どれもなければnil。
    /// Safariの共有ボタンからは、前処理のJS（SharePreprocessing.js）が読んだページのタイトルとURLと選んだ文が届く。
    /// 選んだ文のメニューの「共有」からは、選んだ文がテキストで届く。リンクの共有からは、URLだけが届く。
    private func quote(from providers: [NSItemProvider]) async -> String? {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) {
            let results = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any]
            let page = results?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
            return SharedQuote.body(title: page?["title"] as? String, url: page?["url"] as? String, selection: page?["selection"] as? String)
        }
        // Safariは文字列で渡すが、アプリによってはUTF-8のデータで渡す。
        let item = try? await providers.first { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }?
            .loadItem(forTypeIdentifier: UTType.plainText.identifier)
        let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let url = await url(in: providers.first { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) })
        return SharedQuote.body(title: nil, url: url?.absoluteString, selection: text)
    }

    /// 項目のURLを読む。`loadItem`は、共有元がURLをオブジェクトで登録していると`Data`で返すので、オブジェクトとして読む。
    private func url(in provider: NSItemProvider?) async -> URL? {
        guard let provider else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
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

    /// 画像、動画、音声の表現をファイルで受け取り、App Groupのフォルダーにコピーする。受け取ったファイルは完了の処理を抜けると消されるため、その中でコピーする。
    /// 型が`public.image`だけの項目は、画像のオブジェクトとして読む（`storeImage`）。
    private func store(_ provider: NSItemProvider, in inbox: SharedMediaInbox, id: UUID, index: Int) async throws {
        let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .movie) || $0.conforms(to: .image) || $0.conforms(to: .audio) }
        guard let type else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard type != .image else {
            try await storeImage(provider, in: inbox, id: id, index: index)
            return
        }
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

    /// Xの画像の共有は、型を`public.image`とだけ登録し、`UIImage`を渡す（実機のログで確かめた）。元のファイルは届かないので、拡張の中で書き出す。
    /// アプリは拡張子から形式を決めるので、書き出した形式の拡張子を付けた名前で置く。
    private func storeImage(_ provider: NSItemProvider, in inbox: SharedMediaInbox, id: UUID, index: Int) async throws {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        guard let image = item as? UIImage else {
            logger.error("unsupported image item class=\(String(describing: type(of: item)), privacy: .public)")
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try await Self.write(image, in: inbox, id: id, index: index)
    }

    /// 大きな画像では時間がかかるため、書き出しとコピーはメインスレッドの外でする。HEICは透過も持てるので、どの画像もHEICにする。
    @concurrent
    private static func write(_ image: UIImage, in inbox: SharedMediaInbox, id: UUID, index: Int) async throws {
        guard let data = image.heicData() else { throw CocoaError(.fileWriteUnknown) }
        let folder = FileManager.default.temporaryDirectory.appending(fileName: SafeFileName(UUID().uuidString), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "image.heic")
        try data.write(to: file)
        try inbox.store(file, id: id, index: index)
    }

    private func fail() {
        extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
    }

    /// 共有拡張からアプリを開く公式のAPIはない（`NSExtensionContext.open(_:)`はウィジェットなどでしか効かない）。
    /// responder chainをたどって`UIApplication`を探し、その`open(_:options:completionHandler:)`で開く。
    /// このメソッドは拡張では使えない指定が付いていてコンパイルできないため、セレクターで実装を取り出して呼ぶ。
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
