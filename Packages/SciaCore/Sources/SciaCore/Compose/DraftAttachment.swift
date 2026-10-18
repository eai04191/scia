public import Foundation

/// 下書きに添付したメディア1つの状態。並び順は`StatusDraft.attachments`の順番で、そのまま投稿の`media_ids[]`の順になる。
public struct DraftAttachment: Sendable, Equatable, Identifiable {
    /// 端末の中での識別子。サーバーのIDはアップロードが受け付けられるまで決まらないため、別に持つ。
    public let id: UUID
    public var state: State
    /// 利用者が書いた代替テキスト。サーバーに送った値は`State.uploaded`の添付ファイルの`description`にある。
    public var description: String
    /// 編集している投稿に、もう付いている添付。代替テキストは`PUT /api/v1/media/:id`では直せず（投稿に付いた添付をサーバーが拒む）、
    /// 編集の`media_attributes[]`で一緒に送る。
    public let isAttachedToStatus: Bool
    /// 投稿に付いている添付で、書き換えた代替テキストを編集と一緒に送ったが、届いたか分からない（応答を受け取れなかった）。
    /// サーバーの値が元のままか、送った値か分からないので、次の編集では元と同じ値でも送る。
    public var hasUnconfirmedDescription = false

    public init(id: UUID = UUID(), state: State = .uploading, description: String = "", isAttachedToStatus: Bool = false) {
        self.id = id
        self.state = state
        self.description = description
        self.isAttachedToStatus = isAttachedToStatus
    }

    public enum State: Sendable, Equatable {
        /// ファイルを送っている。
        case uploading
        /// サーバーが受け付け、変換を待っている（`POST /api/v2/media`が202を返した）。
        case processing(serverID: String)
        /// 変換が済み、`url`が入った。
        case uploaded(MediaAttachment)
        /// 失敗した。サーバーが受け付けた後の失敗なら`serverID`が入る。
        /// 処理の待ち時間切れなら同じIDで待ち直せる。それ以外は、ファイルを送り直す。
        case failed(serverID: String?)
    }

    /// サーバー側のID。受け付けられる前と、受け付けられる前に失敗したときはnil。
    public var serverID: String? {
        switch state {
        case .uploading: nil
        case .processing(let serverID): serverID
        case .uploaded(let attachment): attachment.id
        case .failed(let serverID): serverID
        }
    }

    /// 書いた代替テキストを、まだサーバーに送っていない。
    /// 送るのはアップロードが済んでからなので、済む前はfalse。投稿に付いている添付は、編集と一緒に送るのでfalse。
    public var needsDescriptionUpdate: Bool {
        guard !isAttachedToStatus, case .uploaded(let attachment) = state else { return false }
        return (attachment.description ?? "") != description
    }

    /// 投稿に付けられる。アップロードが済み、書いた代替テキストもサーバーに届いている。
    public var isReady: Bool {
        guard case .uploaded = state else { return false }
        return !needsDescriptionUpdate
    }
}
