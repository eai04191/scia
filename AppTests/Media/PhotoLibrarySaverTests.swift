import Foundation
import Photos
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct PhotoLibrarySaverTests {
    /// 本物の写真ライブラリに保存する。写真ライブラリは変更のクロージャを自前のキューで呼ぶため、
    /// クロージャがメインアクターのものになっていると、呼ばれた時点で実行時の検査に落ちる。差し替えた保存では気づけないので、ここで捕まえる。
    /// 許可を求めるダイアログには答えられないため、写真への追加をあらかじめ許可した端末でだけ動かす。保存した画像は端末の写真に残る。
    @Test(.enabled(if: PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized, "写真への追加を許可した端末でだけ動かす"))
    func savesFileToPhotoLibrary() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        let file = URL.temporaryDirectory.appending(path: "PhotoLibrarySaverTests-\(UUID().uuidString).png")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await PhotoLibrarySaver.photoLibrary.save(file)
    }

    /// 画像は写真として、動画とGIF（中身はmp4）は動画として入れる。写真に入らない音声などは保存しない。
    @Test(arguments: [
        ("a.png", PHAssetResourceType.photo),
        ("a.jpeg", .photo),
        ("a.mp4", .video),
        ("a.mov", .video),
    ])
    func resourceTypeFollowsFileFormat(name: String, expected: PHAssetResourceType) {
        #expect(PhotoLibrarySaver.resourceType(of: URL(filePath: "/tmp/\(name)")) == expected)
    }

    @Test func audioCannotBeSaved() {
        #expect(PhotoLibrarySaver.resourceType(of: URL(filePath: "/tmp/a.mp3")) == nil)
    }

    /// システムの説明文をそのまま出さず、種類ごとの文言にする。調べるときのために、種類の番号を補足に添える。
    @Test func failureIsPresentedByKind() {
        #expect(PhotoLibrarySaver.failurePresentation(of: PhotoLibrarySaver.UnsupportedFile()) == ErrorPresentation(message: "写真に入らない形式のファイルです。", code: nil))
        #expect(PhotoLibrarySaver.failurePresentation(of: PHPhotosError(.notEnoughSpace)) == ErrorPresentation(
            message: "端末の空き容量が足りません。",
            code: "PHPhotosError \(PHPhotosError.Code.notEnoughSpace.rawValue)"
        ))
        #expect(PhotoLibrarySaver.failurePresentation(of: PHPhotosError(.invalidResource)).message == "写真に入らない形式のファイルです。")
        #expect(PhotoLibrarySaver.failurePresentation(of: CocoaError(.fileReadNoSuchFile)) == ErrorPresentation(
            message: "写真に追加できませんでした。",
            code: "NSCocoaErrorDomain \(CocoaError.Code.fileReadNoSuchFile.rawValue)"
        ))
    }
}
