public import Foundation

/// メディアのアップロードと処理の待ち合わせで起きる、添付ファイルに固有の失敗。
/// トークンの失効（401）や通信の失敗など、どのAPIでも起きるものはここに含めず、`MastodonAPIError`や`URLError`のまま投げる。
///
/// サーバーのメッセージは利用者の言語に訳されて返るため、メッセージから形式とサイズのどちらで断られたかは見分けない。
/// 文言はサーバーがJSONで返した理由を優先し、HTMLのエラーページなどの本文は出さない（`ErrorPresentation`と同じ方針）。
public enum MediaUploadError: Error, Equatable, Sendable, LocalizedError {
    /// サーバーがファイルを受け付けなかった。形式に対応していない、サイズや画素数が上限を超えたなど。
    /// Mastodonは422を返す。サーバーの前段のプロキシが本文の大きさで断ると413になる。
    case rejected(MastodonAPIError)
    /// サーバーでの変換に失敗した。アップロードでは500、処理の完了を待っている間は422が返る。
    case processingFailed(MastodonAPIError)
    /// 決めた時間を過ぎても、サーバーでの処理が終わらなかった。サーバーには添付ファイルが残っていて、待ち直せる。
    case processingTimedOut(serverID: String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let error): error.serverMessage ?? "サーバーがメディアを受け付けませんでした。"
        case .processingFailed(let error): error.serverMessage ?? "サーバーでメディアを変換できませんでした。"
        case .processingTimedOut: "サーバーでのメディアの処理が終わりませんでした。"
        }
    }
}

/// 投稿を送る前に、アプリの側で止めた失敗。
///
/// サーバーが投稿を拒んだとき（422。本文が長すぎる、添付ファイルが多すぎる、変換の終わっていない添付ファイルがある、
/// 画像と動画を混ぜたなど）は、ここに含めず`MastodonAPIError`のまま投げる。`ErrorPresentation`がその理由をそのまま見せるため。
public enum StatusPostError: Error, Equatable, Sendable, LocalizedError {
    /// アップロードや代替テキストの送信が済んでいない添付ファイルがあり、送らなかった。
    case attachmentsNotReady

    public var errorDescription: String? {
        switch self {
        case .attachmentsNotReady: "アップロードが済んでいないメディアがあります。"
        }
    }
}
