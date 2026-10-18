import Foundation
import SciaCore

/// ビューアで出す知らせの中身。カタログでも同じ文言を並べるため、ビューアの外に置く。
extension Notice {
    /// 写真に保存したこと。数秒で消える。
    static let savedToPhotos = Notice(id: "media.saved", kind: .success, title: "写真に保存しました")

    /// 投稿欄から開いたビューアの、アップロードや代替テキストの送信の状態。済んでいればnil。
    /// 失敗したときだけ押せ、押すと理由と、再試行か削除を出す。
    /// - Parameter status: 投稿欄から開いていなければnil。
    /// - Parameter progress: 送っている間の進み具合。
    static func draftStatus(_ status: ComposeAttachmentStatus?, progress: Double? = nil, showFailure: @escaping @MainActor () -> Void) -> Notice? {
        let failureAction = Action.disclosure(hint: "理由と、再試行か削除を選べます。", handler: showFailure)
        return switch status {
        case nil, .ready: nil
        case .uploading: Notice(id: "media.draft", kind: .progress, title: "アップロード中", value: progress.flatMap(percentText(of:)))
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
        Notice(
            id: downloadID(of: url),
            kind: .progress,
            title: "ダウンロード中",
            value: percentText(of: fraction),
            action: onStop.map { .disclosure(hint: "ダウンロードを止めるか選べます。", handler: $0) } ?? .none
        )
    }

    /// 進み具合の割合。全体の大きさが分かるまでは0のため、nilにして出さない。
    static func percentText(of fraction: Double) -> String? {
        let percent = Int((fraction * 100).rounded(.down))
        return percent > 0 ? "\(percent)%" : nil
    }

    /// 落としている途中のものを、どれの進み具合も出さずに件数で出す。ビューアでいま見ている添付ファイルのものがないときと、ビューアを閉じたあとに2件以上あるとき。
    static func downloads(count: Int, action: Action) -> Notice {
        Notice(id: "media.downloads", kind: .progress, title: "ダウンロード中", value: "\(count)件", action: action)
    }

    /// ビューアを閉じたため、共有のために落としている途中のものを止めた。数秒で消える。
    static let shareStopped = Notice(id: "media.shareStopped", kind: .info, title: "共有を止めました")

    /// 共有や保存の失敗。数秒で消え、押すと理由が出る。
    static func transferFailure(title: String, showReason: @escaping @MainActor () -> Void) -> Notice {
        Notice(id: "media.transferFailure", kind: .failure, title: title, action: .disclosure(hint: "理由を見られます。", handler: showReason))
    }

    /// ビューアでいま見ている添付ファイルの、共有や保存の失敗の文言。何の失敗かは見ているもので分かるため、何ができなかったかだけを言う。
    static func currentTransferFailureTitle(_ failure: MediaTransfers.Failure) -> String {
        switch failure {
        case .download: "ダウンロードできませんでした"
        case .save: "写真に保存できませんでした"
        }
    }

    /// いま見ていない添付ファイルと、ビューアを閉じたあとの、共有や保存の失敗の文言。どれの失敗か分かるよう、種類で示す。
    /// 動画などの投稿は添付ファイルが1つのため、何枚目かより種類のほうが分かりやすい。
    static func transferFailureTitle(of kind: MediaAttachment.Kind, purpose: MediaTransfers.Purpose) -> String {
        let name = switch kind {
        case .image: "画像"
        case .video: "動画"
        case .gifv: "GIF"
        case .audio: "音声"
        case .unknown: "ファイル"
        }
        return switch purpose {
        case .save: "\(name)を保存できませんでした"
        case .share: "\(name)を共有できませんでした"
        }
    }
}
