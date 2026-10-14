import Foundation
import Photos

/// 画像を写真に保存する。テストで写真ライブラリに触れずに保存の結果を確かめられるよう、差し替えられるようにする。
struct PhotoLibrarySaver: Sendable {
    /// 元のファイルを、形式を変えずに写真へ足す。許可されていなければ`NotAuthorized`を投げる。
    let save: @MainActor @Sendable (URL) async throws -> Void

    /// 写真への追加が許可されていない。
    struct NotAuthorized: Error {}

    /// 写真への追加だけの許可を求めて保存する。UIImageから保存すると形式がJPEGなどに変わるため、ファイルをそのまま足す。
    static let photoLibrary = PhotoLibrarySaver { file in
        try await addToPhotoLibrary(file)
    }

    /// 写真ライブラリは変更のクロージャを自前のキューで呼ぶ。メインアクターの中で書くとクロージャもメインアクターのものになり、
    /// 呼ばれた時点で実行時の検査に落ちるため、メインアクターの外で書く。
    private nonisolated static func addToPhotoLibrary(_ file: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw NotAuthorized() }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }
}
