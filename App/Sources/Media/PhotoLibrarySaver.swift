import Foundation
import Photos
import UniformTypeIdentifiers

/// 画像や動画を写真に保存する。テストで写真ライブラリに触れずに保存の結果を確かめられるよう、差し替えられるようにする。
struct PhotoLibrarySaver: Sendable {
    /// 元のファイルを、形式を変えずに写真へ足す。許可されていなければ`NotAuthorized`を投げる。
    let save: @MainActor @Sendable (URL) async throws -> Void

    /// 写真への追加が許可されていない。
    struct NotAuthorized: Error {}

    /// 写真に入らない形式のファイル。
    struct UnsupportedFile: Error {}

    /// 写真への追加だけの許可を求めて保存する。UIImageから保存すると形式がJPEGなどに変わるため、ファイルをそのまま足す。
    static let photoLibrary = PhotoLibrarySaver { file in
        try await addToPhotoLibrary(file)
    }

    /// ファイルを写真に足すときの種類。拡張子から決める。GIFの添付ファイルは中身がmp4のため、動画として入る。
    static func resourceType(of file: URL) -> PHAssetResourceType? {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        return nil
    }

    /// 写真ライブラリは変更のクロージャを自前のキューで呼ぶ。メインアクターの中で書くとクロージャもメインアクターのものになり、
    /// 呼ばれた時点で実行時の検査に落ちるため、メインアクターの外で書く。
    private nonisolated static func addToPhotoLibrary(_ file: URL) async throws {
        guard let resourceType = resourceType(of: file) else { throw UnsupportedFile() }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw NotAuthorized() }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: resourceType, fileURL: file, options: nil)
        }
    }
}
