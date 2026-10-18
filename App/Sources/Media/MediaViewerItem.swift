import SciaCore
import UIKit

/// ビューアの1枚で描く中身。投稿の添付ファイルか、投稿欄で選んだ手元のメディア。
///
/// 手元のメディアを、手元のファイルのURLで作った偽の`MediaAttachment`にしない。IDがサーバーのものと混ざり、
/// `MediaImageStore`が手元のファイルをキャッシュにコピーし、共有と保存が一時ファイルに効いてしまうため。
struct MediaViewerItem {
    /// 開閉の起点のサムネイルを探す鍵。投稿の添付ファイルはそのID、手元のメディアは下書きの添付のID。
    let id: String
    let kind: MediaAttachment.Kind
    /// 幅を高さで割った値。分からなければnil。
    let aspectRatio: Double?
    /// 代替テキスト。空ならnil。書き終えた値を、投稿欄から届く前にビューアで先に見せるため、書き換えられる。
    var description: String?
    let source: Source
    /// 手元のメディアの、アップロードと代替テキストの送信の状態。投稿の添付ファイルではnil。
    let draftStatus: ComposeAttachmentStatus?

    enum Source {
        case server(MediaAttachment)
        /// 手元のファイルと、投稿欄で作ったサムネイル。ファイルは読み込み終えるまでnil。
        case local(file: LocalMediaFile?, thumbnail: UIImage?)
    }

    init(_ attachment: MediaAttachment) {
        id = attachment.id
        kind = attachment.type
        aspectRatio = attachment.aspectRatio
        description = attachment.description.flatMap { $0.isEmpty ? nil : $0 }
        source = .server(attachment)
        draftStatus = nil
    }

    /// 投稿欄で選んだメディア。縦横比はサムネイルから決め、サムネイルを作る前はnilにする。
    init(id: String, kind: MediaAttachment.Kind, description: String, file: LocalMediaFile?, thumbnail: UIImage?, status: ComposeAttachmentStatus) {
        self.id = id
        self.kind = kind
        aspectRatio = thumbnail.flatMap { $0.size.height > 0 ? Double($0.size.width / $0.size.height) : nil }
        self.description = description.isEmpty ? nil : description
        source = .local(file: file, thumbnail: thumbnail)
        draftStatus = status
    }

    /// 投稿欄で編集している投稿に、もう付いている添付ファイル。開閉の起点は投稿欄のサムネイルなので、IDは下書きの添付のIDにする。
    /// 代替テキストは、投稿欄で書き換えた値を出す。
    init(id: String, attached attachment: MediaAttachment, description: String, status: ComposeAttachmentStatus) {
        self.id = id
        kind = attachment.type
        aspectRatio = attachment.aspectRatio
        self.description = description.isEmpty ? nil : description
        source = .server(attachment)
        draftStatus = status
    }

    /// 投稿の添付ファイル。手元のメディアではnil。
    var serverAttachment: MediaAttachment? {
        guard case .server(let attachment) = source else { return nil }
        return attachment
    }

    /// 手元のファイル。投稿の添付ファイルと、読み込む前の手元のメディアではnil。
    var localFile: LocalMediaFile? {
        guard case .local(let file, _) = source else { return nil }
        return file
    }

    /// 投稿欄で作ったサムネイル。
    var localThumbnail: UIImage? {
        guard case .local(_, let thumbnail) = source else { return nil }
        return thumbnail
    }
}
