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
        let kind: MediaAttachment.Kind = type.conforms(to: .gif) ? .gifv : type.conforms(to: .movie) ? .video : .image
        let mimeType = type.preferredMIMEType ?? (kind == .video ? "video/mp4" : "image/jpeg")
        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? LocalMediaError.loadFailed)
                    return
                }
                do {
                    // 元の名前のままサーバーに送れるよう、選ぶたびにディレクトリを分ける。
                    let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appending(path: url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return LocalMediaFile(url: url, mimeType: mimeType, kind: kind)
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
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return try? await UIImage(cgImage: generator.image(at: .zero).image)
        }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
