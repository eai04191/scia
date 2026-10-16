import Foundation

/// ビューアで出す知らせの中身。カタログでも同じ文言を並べるため、ビューアの外に置く。
extension Notice {
    /// 写真に保存したこと。数秒で消える。
    static let savedToPhotos = Notice(id: "media.saved", kind: .success, title: "写真に保存しました")

    /// 投稿欄から開いたビューアの、アップロードや代替テキストの送信の状態。済んでいればnil。
    /// 失敗したときだけ押せ、押すと理由と、再試行か削除を出す。
    /// - Parameter status: 投稿欄から開いていなければnil。
    static func draftStatus(_ status: ComposeAttachmentStatus?, showFailure: @escaping @MainActor () -> Void) -> Notice? {
        let failureAction = Action.disclosure(hint: "理由と、再試行か削除を選べます。", handler: showFailure)
        return switch status {
        case nil, .ready: nil
        case .uploading: Notice(id: "media.draft", kind: .progress, title: "アップロード中")
        case .processing: Notice(id: "media.draft", kind: .progress, title: "サーバーで処理中")
        case .sendingDescription: Notice(id: "media.draft", kind: .progress, title: "代替テキストを送信中")
        case .failed: Notice(id: "media.draft", kind: .failure, title: "アップロードできませんでした", action: failureAction)
        case .descriptionFailed: Notice(id: "media.draft", kind: .failure, title: "代替テキストを送信できませんでした", action: failureAction)
        }
    }

    static let downloadIDPrefix = "media.download."

    /// `url`を落としている途中の知らせのid。
    static func downloadID(of url: URL) -> String {
        downloadIDPrefix + url.absoluteString
    }

    /// 共有や保存のために落としている途中。押すと止めるかの確認を出す。全体の大きさが分かるまでは`fraction`が0のため、割合を出さない。
    /// - Parameter onStop: nilなら押せない。落とし終えて保存している間など、止められないとき。
    static func download(of url: URL, fraction: Double, onStop: (@MainActor () -> Void)?) -> Notice {
        let percent = Int((fraction * 100).rounded(.down))
        return Notice(
            id: downloadID(of: url),
            kind: .progress,
            title: "ダウンロード中",
            value: percent > 0 ? "\(percent)%" : nil,
            action: onStop.map { .disclosure(hint: "ダウンロードを止めるか選べます。", handler: $0) } ?? .none
        )
    }
}
