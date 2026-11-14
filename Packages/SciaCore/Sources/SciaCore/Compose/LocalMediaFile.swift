public import Foundation

/// 端末から選び、アプリの一時ディレクトリにコピーしたメディアのファイル。アップロードと、投稿欄のサムネイルに使う。
///
/// ファイルは、このファイルのためだけに作ったフォルダーに置く。添付から外したときと投稿できたときに、フォルダーごと消すため（`remove()`）。
/// 使う人のファイルやほかのアプリから受け取ったファイルは、場所をそのまま渡さず、`init(copying:in:mimeType:kind:)`でコピーして作る。
public struct LocalMediaFile: Sendable, Equatable {
    public let url: URL
    public let mimeType: String
    public let kind: MediaAttachment.Kind

    /// - Parameter url: このファイルのためだけに作ったフォルダーに置いたファイル。`remove()`は、このファイルのあるフォルダーを中身ごと消す。
    ///   使う人のファイルの場所を渡すと、そのファイルのあるフォルダーが消える。
    public init(url: URL, mimeType: String, kind: MediaAttachment.Kind) {
        self.url = url
        self.mimeType = mimeType
        self.kind = kind
    }

    /// `source`を、`directory`の中に作ったこのファイルのためだけのフォルダーへコピーして作る。元のファイルには触れない。
    /// - Parameter directory: コピーを置く場所。アプリの一時ディレクトリの中のフォルダーを渡す。
    public init(copying source: URL, in directory: URL, mimeType: String, kind: MediaAttachment.Kind) throws {
        self.init(url: try Self.ownedCopy(of: source, in: directory), mimeType: mimeType, kind: kind)
    }

    /// `source`を、`directory`の中に作ったそのファイルのためだけのフォルダーへコピーし、コピーした先を返す。
    public static func ownedCopy(of source: URL, in directory: URL) throws -> URL {
        // 元の名前のままサーバーに送れるよう、コピーするたびにフォルダーを分ける。
        let folder = directory.appending(fileName: SafeFileName(UUID().uuidString), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 名前はほかのアプリから受け取ったファイルのものでありうるので、フォルダーの直下に収める。
        let destination = folder.appending(fileName: SafeFileName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
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
        case .loadFailed: "デバイスからメディアを読み込めませんでした。"
        }
    }
}
