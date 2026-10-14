#if DEBUG
import Foundation

/// デバッグメニューと同じ操作を、`xcrun simctl openurl '<端末>' 'scia-debug://dummy/images'`のようにURLで呼ぶ。
/// agentがメニューを開いて叩かずに、コマンドで確認の準備をするため。
enum DebugURL: Equatable {
    static let scheme = "scia-debug"

    /// `scia-debug://dummy/<DebugDummyPost.rawValue>`
    case dummy(DebugDummyPost)

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "dummy":
            guard let post = DebugDummyPost(rawValue: url.lastPathComponent) else { return nil }
            self = .dummy(post)
        default:
            return nil
        }
    }
}
#endif
