public import Foundation

/// 端末から選び、アプリの一時ディレクトリにコピーしたメディアのファイル。アップロードと、投稿欄のサムネイルに使う。
public struct LocalMediaFile: Sendable, Equatable {
    public let url: URL
    public let mimeType: String
    public let kind: MediaAttachment.Kind

    public init(url: URL, mimeType: String, kind: MediaAttachment.Kind) {
        self.url = url
        self.mimeType = mimeType
        self.kind = kind
    }

    /// ファイルを、コピーしたときに作ったディレクトリごと消す。添付から外したときと、投稿できたときに呼ぶ。
    public func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// アップロードするためにファイルを読む。動画では大きくなるため、メインスレッドの外で読む。
    @concurrent
    public func upload(description: String) async throws -> MediaUpload {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return MediaUpload(data: data, filename: url.lastPathComponent, mimeType: mimeType, description: description)
    }
}

/// ピッカーで選んだメディア1つ。ファイルは、添付に足すと決まってから読み込む。
public struct PickedMedia {
    /// ピッカーの`assetIdentifier`。開き直したときに前の選択として渡す。
    public let assetIdentifier: String
    /// 引数のMIMEタイプの形式を避けて読み込む。サーバーが処理できない形式を避けて、同じ写真のJPEGを受け取るのに使う。
    public let load: @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile

    public init(assetIdentifier: String, load: @escaping @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile) {
        self.assetIdentifier = assetIdentifier
        self.load = load
    }
}

/// 投稿欄にペーストしたか、共有で受け取ったメディア1つ。ピッカーで選んだものと違い、あとから読み直せない。
public struct PastedMedia {
    /// 上限を超えて足さなかったときに、知らせる文言を選ぶのに使う。
    public let kind: MediaAttachment.Kind
    public let load: @MainActor () async throws -> LocalMediaFile
    /// 添付に足さなかったときに呼ぶ。読み込んだファイルを消す。
    public var discard: @MainActor () -> Void = {}

    public init(kind: MediaAttachment.Kind, load: @escaping @MainActor () async throws -> LocalMediaFile, discard: @escaping @MainActor () -> Void = {}) {
        self.kind = kind
        self.load = load
        self.discard = discard
    }
}

/// 端末からメディアを読み込めなかった。
public enum LocalMediaError: Error, LocalizedError {
    /// 画像でも動画でもないものが届いた。ピッカーで画像と動画に絞っているので、普通は起きない。
    case unsupportedType
    /// 写真ライブラリからファイルを受け取れなかった。iCloudからの取得に失敗したときなど。
    case loadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: "このメディアの形式は添付できません。"
        case .loadFailed: "端末からメディアを読み込めませんでした。"
        }
    }
}
