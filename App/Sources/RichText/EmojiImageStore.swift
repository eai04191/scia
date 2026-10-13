import Foundation
import os
import SciaCore
import UIKit

/// カスタム絵文字の画像を読み込み、メモリに持つ。
/// 1つのタイムラインで使う絵文字は数百件程度で1枚も小さいため、上限を設けずに持ち続ける。
@MainActor
final class EmojiImageStore {
    typealias Fetch = @Sendable (URL) async throws -> Data

    private enum State {
        case loading
        case loaded(UIImage)
        case failed
    }

    private struct Listener {
        weak var owner: AnyObject?
        let onLoad: @MainActor (Set<URL>) -> Void
    }

    private let fetch: Fetch
    private var states: [URL: State] = [:]
    private var listeners: [Listener] = []
    private var pendingNotification: Set<URL> = []
    private let logger = SciaLog.logger(category: "emoji")

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返す。
    func image(for url: URL) -> UIImage? {
        switch states[url] {
        case .loaded(let image):
            return image
        case .loading, .failed:
            return nil
        case nil:
            load(url)
            return nil
        }
    }

    func hasFailed(_ url: URL) -> Bool {
        if case .failed = states[url] { return true }
        return false
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Set<URL>) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    private func load(_ url: URL) {
        states[url] = .loading
        Task {
            let state: State
            do {
                let data = try await fetch(url)
                if let image = UIImage(data: data) {
                    state = .loaded(image)
                } else {
                    logger.error("emoji decode failed url=\(url.absoluteString, privacy: .public)")
                    state = .failed
                }
            } catch {
                logger.error("emoji load failed url=\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                state = .failed
            }
            states[url] = state
            notify(url)
        }
    }

    /// 同じ時期に届いた画像をまとめて知らせ、セルの再構成を減らす。
    private func notify(_ url: URL) {
        let isFirst = pendingNotification.isEmpty
        pendingNotification.insert(url)
        guard isFirst else { return }
        Task {
            let urls = pendingNotification
            pendingNotification = []
            listeners.removeAll { $0.owner == nil }
            for listener in listeners {
                listener.onLoad(urls)
            }
        }
    }
}
