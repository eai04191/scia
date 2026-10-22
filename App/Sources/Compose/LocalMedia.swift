import AVFoundation
import ImageIO
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 端末から選び、アプリの一時ディレクトリにコピーしたメディアのファイル。アップロードと、投稿欄のサムネイルに使う。
struct LocalMediaFile: Sendable, Equatable {
    let url: URL
    let mimeType: String
    let kind: MediaAttachment.Kind

    /// ファイルを、コピーしたときに作ったディレクトリごと消す。添付から外したときと、投稿できたときに呼ぶ。
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// ピッカーで選んだメディア1つ。ファイルは、添付に足すと決まってから読み込む。
struct PickedMedia {
    /// ピッカーの`assetIdentifier`。開き直したときに前の選択として渡す。
    let assetIdentifier: String
    /// 引数のMIMEタイプの形式を避けて読み込む。サーバーが処理できない形式を避けて、同じ写真のJPEGを受け取るのに使う。
    let load: @MainActor (_ avoiding: Set<String>) async throws -> LocalMediaFile
}

/// 投稿欄にペーストしたか、共有で受け取ったメディア1つ。ピッカーで選んだものと違い、あとから読み直せない。
struct PastedMedia {
    /// 上限を超えて足さなかったときに、知らせる文言を選ぶのに使う。
    let kind: MediaAttachment.Kind
    let load: @MainActor () async throws -> LocalMediaFile
    /// 添付に足さなかったときに呼ぶ。読み込んだファイルを消す。
    var discard: @MainActor () -> Void = {}
}

/// 端末からメディアを読み込めなかった。
enum LocalMediaError: Error, LocalizedError {
    /// 画像でも動画でもないものが届いた。ピッカーで画像と動画に絞っているので、普通は起きない。
    case unsupportedType
    /// 写真ライブラリからファイルを受け取れなかった。iCloudからの取得に失敗したときなど。
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "このメディアの形式は添付できません。"
        case .loadFailed: "端末からメディアを読み込めませんでした。"
        }
    }
}

enum LocalMediaLoader {
    /// 選んだメディアをコピーする先。起動し直すと、OSが一時ディレクトリの中身をいずれ消す。
    static let directory = FileManager.default.temporaryDirectory.appending(path: "ComposeMedia", directoryHint: .isDirectory)

    /// ピッカーの選択から、読み込みを後回しにした`PickedMedia`を作る。
    /// 前に選んだメディアは`itemProvider`が空で返るため読み込めないが、それらは添付に残っていて読み込まない。
    @MainActor
    static func picked(assetIdentifier: String, provider: NSItemProvider) -> PickedMedia {
        PickedMedia(assetIdentifier: assetIdentifier) { avoiding in try await load(from: provider, avoiding: avoiding) }
    }

    /// 画像か動画の表現をファイルで受け取り、一時ディレクトリにコピーする。
    /// 受け取ったファイルは完了の処理を抜けると消されるため、その中でコピーする。
    ///
    /// ピッカーには形式を変えさせない（`MediaPickerSheet`）ので、写真はHEICのまま並ぶ。その後ろに、ピッカーが作るJPEGも並ぶ
    /// （シミュレーターで確かめた並びで、ドキュメントには書かれていない）。`avoiding`の形式を飛ばすと、同じ写真のJPEGを受け取れる。
    @MainActor
    static func load(from provider: NSItemProvider, avoiding: Set<String>) async throws -> LocalMediaFile {
        let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .filter { $0.conforms(to: .movie) || $0.conforms(to: .image) }
            .first { $0.preferredMIMEType.map { !avoiding.contains($0) } ?? true }
        guard let type else { throw LocalMediaError.unsupportedType }
        let kind = Self.kind(of: type)
        let mimeType = type.preferredMIMEType ?? (kind == .video ? "video/mp4" : "image/jpeg")
        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? LocalMediaError.loadFailed)
                    return
                }
                do {
                    continuation.resume(returning: try copyToDirectory(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return LocalMediaFile(url: url, mimeType: mimeType, kind: kind)
    }

    /// ファイルを一時ディレクトリにコピーし、コピーした先を返す。
    private static func copyToDirectory(_ url: URL) throws -> URL {
        // 元の名前のままサーバーに送れるよう、選ぶたびにディレクトリを分ける。
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// 添付したときの種類。GIFは、サーバーが音のない動画（gifv）に変える。
    private static func kind(of type: UTType) -> MediaAttachment.Kind {
        type.conforms(to: .gif) ? .gifv : type.conforms(to: .movie) ? .video : .image
    }

    /// 投稿欄で受け付けるメディアの型。
    static let mediaTypes: [UTType] = [.image, .movie]

    /// クリップボードの項目が、本文ではなく添付に回すメディアなら、その型を返す。文字を持つ項目は本文に入れるのでnil。
    /// 文字と画像を両方持つ項目（画像の説明の文字が付いたものなど）は、本文にペーストするつもりのことが多いため、文字を優先する。
    static func pastedMediaType(in provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard !types.contains(where: { $0.conforms(to: .plainText) }) else { return nil }
        return types.first { type in mediaTypes.contains { type.conforms(to: $0) } }
    }

    /// ペーストした項目の読み込みを、その場で始める。クリップボードの中身はあとから変わり、前にコピーしたものは読めなくなることがあるため
    /// （シミュレーターでは、「Operation not authorized」（PBErrorDomain 13）で読めなくなった）。
    /// 添付に足すかは、1回のペーストの項目がそろってから決めるので、足す前から読み込んでおく。
    /// クリップボードには形式を選び直せる表現が並ぶとは限らないので、避ける形式は渡さない。処理できないと分かった形式は、送る前に作り直す（`ImagePlan.make`）。
    @MainActor
    static func startLoadingPasted(from provider: NSItemProvider, type: UTType) -> PastedMedia {
        let loading = Task.immediate { @MainActor in try await load(from: provider, avoiding: []) }
        return PastedMedia(kind: kind(of: type), load: { try await loading.value }, discard: {
            Task { try? await loading.value.remove() }
        })
    }

    /// クリップボードの項目が、ファイルを指すURLを持つか。MacのFinderでコピーしたファイルは、中身ではなく、ファイルのURL
    /// （`file:///.file/id=…`の形）、ファイル名の文字、Finderのアイコンの画像として入る（Macで確かめた）。文字やアイコンで振り分けると、
    /// URLが本文に入るかアイコンが添付されるため、こうした項目は指す先のファイルで振り分ける（`startLoadingPastedFile`）。
    static func hasFileURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// ペーストした項目のURLが画像か動画のファイルを指すなら、そのファイルのコピーを始める。それ以外のファイルならnil。
    @MainActor
    static func startLoadingPastedFile(from provider: NSItemProvider) async -> PastedMedia? {
        guard let url = await fileURL(in: provider) else { return nil }
        return startCopyingFile(url)
    }

    /// 画像か動画のファイルなら、一時ディレクトリへのコピーを始める。それ以外のファイルならnil。
    /// ペーストしたファイルと、共有拡張から受け取ったファイル（`SharedMediaInbox`）に使う。
    @MainActor
    static func startCopyingFile(_ url: URL) -> PastedMedia? {
        guard let type = UTType(filenameExtension: url.pathExtension), mediaTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        let kind = kind(of: type)
        let mimeType = type.preferredMIMEType ?? (kind == .video ? "video/mp4" : "image/jpeg")
        let loading = Task.immediate { try await copyPastedFile(url, mimeType: mimeType, kind: kind) }
        return PastedMedia(kind: kind, load: { try await loading.value }, discard: {
            Task { try? await loading.value.remove() }
        })
    }

    /// 項目のURLを、ファイルのパスの形で読む。Finderの`file:///.file/id=…`は拡張子を持たないため、パスに直して形式を見る。
    @MainActor
    private static func fileURL(in provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url.flatMap { ($0 as NSURL).filePathURL })
            }
        }
    }

    /// 動画では大きくなるため、メインスレッドの外でコピーする。
    @concurrent
    private static func copyPastedFile(_ url: URL, mimeType: String, kind: MediaAttachment.Kind) async throws -> LocalMediaFile {
        LocalMediaFile(url: try copyToDirectory(url), mimeType: mimeType, kind: kind)
    }

    /// クリップボードに、添付に回すメディアの項目があるか。型だけを見るので、ペーストの許可を求められない。
    static func pasteboardHasMedia(_ pasteboard: UIPasteboard) -> Bool {
        (pasteboard.types(forItemSet: nil) ?? []).contains { identifiers in
            let types = identifiers.compactMap { UTType($0) }
            return !types.contains { $0.conforms(to: .plainText) }
                && types.contains { type in mediaTypes.contains { type.conforms(to: $0) } }
        }
    }

    /// アップロードするためにファイルを読む。動画では大きくなるため、メインスレッドの外で読む。
    @concurrent
    static func upload(of file: LocalMediaFile, description: String) async throws -> MediaUpload {
        let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
        return MediaUpload(data: data, filename: file.url.lastPathComponent, mimeType: file.mimeType, description: description)
    }
}

enum LocalMediaThumbnail {
    /// 表示する大きさまで縮めたサムネイル。元の大きさで読むと、大きな写真では時間がかかり、メモリも食う。動画は最初のコマを使う。
    @concurrent
    static func make(for file: LocalMediaFile, maxPixelSize: CGFloat) async -> UIImage? {
        if file.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            generator.appliesPreferredTrackTransform = true
            // 既定ではSDRに変換される。HDRの動画のコマもHDRのまま作り、描く明るさは画面ごとのtraitで決める。
            generator.dynamicRangePolicy = .matchSource
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return try? await UIImage(cgImage: generator.image(at: .zero).image)
        }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // HDRの写真はHDRのまま展開し、描く明るさは画面ごとのtraitで決める。`MediaImageStore`と同じ。
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
