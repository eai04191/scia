import Foundation
import ImageIO
import SciaCore
import SciaTesting
import UniformTypeIdentifiers
import Testing
import UIKit
@testable import Scia

/// 投稿欄で選んだメディアのアップロードと、投稿の`media_ids[]`。
@MainActor
struct ComposeModelMediaTests {
    private struct Failure: Error {}

    /// アップロードを止めておき、テストから1件ずつ返す。
    @MainActor
    private final class FakeServer {
        var uploads: [MediaUpload] = []
        var waits: [String] = []
        private var pendingUploads: [(filename: String, continuation: CheckedContinuation<MediaAttachment, any Error>)] = []
        /// trueなら、アップロードを止めずにすぐ済ませる。
        var completesImmediately = true
        var uploadResult: (MediaUpload) throws -> MediaAttachment = { upload in
            attachment(id: "m-\(upload.filename)", processed: true)
        }
        var waitResult: (String) throws -> MediaAttachment = { id in attachment(id: id, processed: true) }
        /// 処理できないと覚えた画像の形式。
        var unprocessableImageTypes: [String] = []
        var descriptionUpdates: [(id: String, description: String)] = []
        var descriptionResult: (String, String) throws -> MediaAttachment = { id, description in
            attachment(id: id, processed: true, description: description)
        }
        /// trueなら、代替テキストの送信を止めておき、テストから返す。
        var holdsDescriptionUpdates = false
        private var pendingDescriptionUpdates: [(id: String, description: String, continuation: CheckedContinuation<MediaAttachment, any Error>)] = []

        var service: ComposeMediaService {
            ComposeMediaService(
                upload: { [self] upload in
                    uploads.append(upload)
                    if completesImmediately { return try uploadResult(upload) }
                    return try await withCheckedThrowingContinuation { pendingUploads.append((upload.filename, $0)) }
                },
                waitUntilProcessed: { [self] id in
                    waits.append(id)
                    return try waitResult(id)
                },
                updateDescription: { [self] id, description in
                    descriptionUpdates.append((id, description))
                    if holdsDescriptionUpdates {
                        return try await withCheckedThrowingContinuation { pendingDescriptionUpdates.append((id, description, $0)) }
                    }
                    return try descriptionResult(id, description)
                },
                makeThumbnail: { _ in nil },
                unprocessableImageTypes: { [self] in Set(unprocessableImageTypes) },
                recordUnprocessableImageType: { [self] in unprocessableImageTypes.append($0) },
                preparation: { .keepsOriginal }
            )
        }

        func finishNextUpload(with result: Result<MediaAttachment, any Error>) {
            pendingUploads.removeFirst().continuation.resume(with: result)
        }

        /// 止めていたアップロードのうち、そのファイル名のものを済ませる。2件を止めたときは届いた順が決まっていないので、こちらで選ぶ。
        func finishUpload(named filename: String, with result: Result<MediaAttachment, any Error>) throws {
            let index = try #require(pendingUploads.firstIndex { $0.filename == filename }, "\(filename)のアップロードが止まっていません")
            pendingUploads.remove(at: index).continuation.resume(with: result)
        }

        var pendingCount: Int { pendingUploads.count }

        var pendingDescriptionCount: Int { pendingDescriptionUpdates.count }

        /// 止めていた代替テキストの送信を、送った値で済ませる。
        func finishNextDescriptionUpdate() {
            let pending = pendingDescriptionUpdates.removeFirst()
            pending.continuation.resume(returning: attachment(id: pending.id, processed: true, description: pending.description))
        }
    }

    private static func attachment(id: String, processed: Bool, description: String? = nil) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: processed ? URL(string: "https://example.social/\(id).jpg") : nil, previewUrl: nil, description: description)
    }

    private func picked(_ id: String) throws -> PickedMedia {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jpg")
        // 送る前に大きさを読むので、読める画像にする。
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        } as Data?).write(to: url)
        return PickedMedia(assetIdentifier: id) { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }
    }

    /// ペーストしたメディア。`kind`は、上限を超えて足さなかったときに知らせる種類にだけ使う。
    private func pasted(_ name: String, kind: MediaAttachment.Kind = .image) throws -> PastedMedia {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).jpg")
        try writePhoto(width: 4, height: 3, to: url)
        return PastedMedia(kind: kind) { LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }
    }

    private func makeModel(_ server: FakeServer, post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: server.service, post: post)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    /// 画像を作り直すような、別のスレッドで時間のかかる処理が済むまで待つ。
    private func settleSlowly(until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(condition, sourceLocation: sourceLocation)
    }

    /// 非同期のアップロードが進むまで待つ。
    private func settle(until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(condition, sourceLocation: sourceLocation)
    }

    private func isSettled(_ model: ComposeModel) -> Bool {
        model.attachments.allSatisfy { attachment in
            switch attachment.state {
            case .uploaded, .failed: true
            case .uploading, .processing: false
            }
        }
    }

    /// 写真を書き出す。`noise`なら、縮めると容量が減るよう、画素ごとにばらばらの色にする。
    private func writePhoto(width: Int, height: Int, noise: Bool = false, to url: URL) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard noise else { return }
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    UIColor(hue: .random(in: 0...1), saturation: 1, brightness: .random(in: 0.3...1), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        try data.write(to: url)
    }

    /// 対応形式として返しながらHEICを処理できないサーバー（Mastodon 4.7.2と4.7.3）では、同じ写真のJPEGで1回だけ送り直し、その形式を覚える。
    @Test func resendsUnprocessableHEICAsJPEGOnce() async throws {
        let server = FakeServer()
        server.uploadResult = { upload in
            guard upload.mimeType != "image/heic" else {
                throw MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media"))
            }
            return Self.attachment(id: "m-\(upload.filename)", processed: true)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // ピッカーから読み込むたびに別のディレクトリへコピーするのと同じく、HEICとJPEGを別のディレクトリに置く。送り直すときはHEICをディレクトリごと消すため。
        let jpegFolder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: jpegFolder, withIntermediateDirectories: true)
        let heic = folder.appending(path: "a.heic")
        let jpeg = jpegFolder.appending(path: "a.jpg")
        try writePhoto(width: 40, height: 30, to: heic)
        try writePhoto(width: 40, height: 30, to: jpeg)
        var avoided: [Set<String>] = []
        let picked = PickedMedia(assetIdentifier: "a") { avoiding in
            avoided.append(avoiding)
            return avoiding.contains("image/heic")
                ? LocalMediaFile(url: jpeg, mimeType: "image/jpeg", kind: .image)
                : LocalMediaFile(url: heic, mimeType: "image/heic", kind: .image)
        }
        let model = makeModel(server)

        model.applyPickerSelection([picked])
        try await settleSlowly { isSettled(model) }

        #expect(server.uploads.map(\.mimeType) == ["image/heic", "image/jpeg"])
        #expect(server.unprocessableImageTypes == ["image/heic"])
        #expect(avoided == [[], ["image/heic"]])
        #expect(model.attachmentStatus(of: try #require(model.attachments.first?.id)) == .ready)
    }

    /// 元のまま送る写真でも、撮った場所の位置情報は除いて送る。サーバーが除くかはAPIで分からないため。
    @Test func removesLocationBeforeSending() async throws {
        let server = FakeServer()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "located.jpg")
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.cgImage)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let model = makeModel(server)

        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }])
        try await settleSlowly { isSettled(model) }

        let upload = try #require(server.uploads.first)
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(upload.mimeType == "image/jpeg")
    }

    /// 位置情報のあるHEICは、位置情報だけを除いて送る。それを処理できないと500が返ったら、作り直したものではないので、ピッカーから同じ写真のJPEGを受け取り直して送る。
    @Test func resendsLocatedHEICAsJPEGFromPicker() async throws {
        let server = FakeServer()
        server.uploadResult = { upload in
            guard upload.mimeType != "image/heic" else {
                throw MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media"))
            }
            return Self.attachment(id: "m-\(upload.filename)", processed: true)
        }
        func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let heic = try folder().appending(path: "a.heic")
        let jpeg = try folder().appending(path: "a.jpg")
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.cgImage)
        let destination = try #require(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try writePhoto(width: 40, height: 30, to: jpeg)
        let picked = PickedMedia(assetIdentifier: "a") { avoiding in
            avoiding.contains("image/heic")
                ? LocalMediaFile(url: jpeg, mimeType: "image/jpeg", kind: .image)
                : LocalMediaFile(url: heic, mimeType: "image/heic", kind: .image)
        }
        let model = makeModel(server)

        model.applyPickerSelection([picked])
        try await settleSlowly { isSettled(model) }

        #expect(server.uploads.map(\.mimeType) == ["image/heic", "image/jpeg"])
        #expect(model.attachmentStatus(of: try #require(model.attachments.first?.id)) == .ready)
    }

    /// サーバーの容量の上限を超える画像は、収まるまで縮めて送り、使う人が選んでいない変化なので知らせる。
    @Test func shrinksImageToFitTheServerSizeLimitAndTells() async throws {
        let server = FakeServer()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "large.jpg")
        try writePhoto(width: 800, height: 600, noise: true, to: url)
        let byteCount = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: server.service) { _ in }
        model.apply(
            configuration: InstanceConfiguration(
                streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4,
                mediaDescriptionLimit: 1500, supportedMediaTypes: ["image/jpeg"],
                mediaLimits: MediaLimits(imageSizeLimit: byteCount / 2, imageMatrixLimit: nil, videoSizeLimit: nil, videoMatrixLimit: nil, videoFrameRateLimit: nil)
            ),
            defaultVisibility: .public,
            defaultSensitive: nil
        )
        var reduced: [MediaAttachment.Kind] = []
        model.onMediaReduced = { reduced.append($0) }

        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }])
        try await settleSlowly { isSettled(model) }

        let upload = try #require(server.uploads.first)
        #expect(upload.data.count <= byteCount / 2)
        #expect(upload.mimeType == "image/jpeg")
        #expect(reduced == [.image])
        let id = try #require(model.attachments.first?.id)
        #expect(model.localMedia[id]?.reduction?.fromSize == PixelSize(width: 800, height: 600))
    }

    /// 切り抜くと、送り終えた添付も、切り抜いた画像で代替テキストと一緒に送り直し、投稿には新しいメディアを付ける。元のファイルは残す。
    @Test func croppingResendsCroppedImageWithDescription() async throws {
        let server = FakeServer()
        var uploadCount = 0
        server.uploadResult = { upload in
            uploadCount += 1
            return Self.attachment(id: "m\(uploadCount)", processed: true, description: upload.description)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "photo.jpg")
        try writePhoto(width: 400, height: 300, to: url)
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }
        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }])
        try await settleSlowly { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        model.setDescription("猫", of: id)
        try await settle { model.attachments.first?.isReady == true }
        #expect(model.canCrop(id))

        // 時計回りに1回回して、回したあとの上半分を残す。
        model.setCrop(ImageCrop(quarterTurns: 1, rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)), preview: nil, of: id)
        #expect(model.attachmentStatus(of: id) == .uploading)
        #expect(!model.canPost)
        try await settleSlowly { isSettled(model) }
        #expect(model.localMedia[id]?.file?.url == url)
        await model.submit()

        #expect(server.uploads.count == 2)
        let upload = try #require(server.uploads.last)
        #expect(upload.description == "猫")
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 300)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 200)
        #expect(sent.first?.mediaIDs == ["m2"])
    }

    /// 同じ範囲を選び直しても送り直さない。範囲を外すと、元のまま送り直す。
    @Test func clearingCropResendsOriginal() async throws {
        let server = FakeServer()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "photo.jpg")
        try writePhoto(width: 40, height: 30, to: url)
        let model = makeModel(server)
        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }])
        try await settleSlowly { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        let crop = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))

        model.setCrop(crop, preview: nil, of: id)
        try await settleSlowly { isSettled(model) && server.uploads.count == 2 }
        model.setCrop(crop, preview: nil, of: id)
        model.setCrop(nil, preview: nil, of: id)
        try await settleSlowly { isSettled(model) && server.uploads.count == 3 }

        let sizes = try server.uploads.map { upload in
            let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
            return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])[kCGImagePropertyPixelWidth] as? Int
        }
        #expect(sizes == [40, 20, 40])
    }

    /// 送っている間に切り抜くと、止めた前のアップロードに処理できない形式のエラーが届いても、JPEGで送り直さず、元のファイルを消さない。
    /// 送り直す経路は、ピッカーから受け取り直す前に元のファイルを消すため、止めたことを確かめずに進むと、切り抜き直せなくなる。
    @Test func cancelledUploadDoesNotDeleteOriginalWhenCropping() async throws {
        let server = FakeServer()
        server.completesImmediately = false
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "photo.heic")
        try writePhoto(width: 40, height: 30, to: url)
        var loads = 0
        let model = makeModel(server)
        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in
            loads += 1
            return LocalMediaFile(url: url, mimeType: "image/heic", kind: .image)
        }])
        try await settle { server.pendingCount == 1 }
        let id = try #require(model.attachments.first?.id)

        model.setCrop(ImageCrop(quarterTurns: 0, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)), preview: nil, of: id)
        server.finishNextUpload(with: .failure(MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media"))))
        try await settleSlowly { server.pendingCount == 1 }

        #expect(loads == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(model.canCrop(id))
    }

    /// 開き直して動かさずに完了したときのように、割合が丸めの誤差でずれても、同じ画素を選んでいれば送り直さない。
    @Test func cropSelectingSamePixelsDoesNotResend() async throws {
        let server = FakeServer()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "photo.jpg")
        try writePhoto(width: 40, height: 30, to: url)
        let model = makeModel(server)
        model.applyPickerSelection([PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }])
        try await settleSlowly { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        model.setCrop(ImageCrop(quarterTurns: 0, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)), preview: nil, of: id)
        try await settleSlowly { isSettled(model) && server.uploads.count == 2 }

        model.setCrop(ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.000_001, y: 0, width: 0.499_998, height: 0.999_999)), preview: nil, of: id)
        // 全体を選んだ範囲は、切り抜かないのと同じ。
        model.setCrop(nil, preview: nil, of: id)
        try await settleSlowly { isSettled(model) && server.uploads.count == 3 }
        model.setCrop(ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.000_001, y: 0, width: 0.999_998, height: 1)), preview: nil, of: id)

        #expect(model.attachmentStatus(of: id) == .ready)
        #expect(server.uploads.count == 3)
    }

    /// 動画は切り抜かない。
    @Test func cannotCropVideo() async throws {
        let server = FakeServer()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "clip.mov")
        try Data([0]).write(to: url)
        server.completesImmediately = false
        let model = makeModel(server)
        model.applyPickerSelection([PickedMedia(assetIdentifier: "v") { _ in LocalMediaFile(url: url, mimeType: "video/quicktime", kind: .video) }])
        try await settle { model.localMedia.values.first?.file != nil }
        #expect(!model.canCrop(try #require(model.attachments.first?.id)))
    }

    @Test func postsMediaIDsInPickerOrderWithEmptyText() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }

        model.applyPickerSelection([try picked("b"), try picked("a")])
        try await settle { isSettled(model) }
        await model.submit()

        #expect(sent.first?.mediaIDs == ["m-b.jpg", "m-a.jpg"])
        #expect(model.attachments.isEmpty)
    }

    /// 注意書きの欄を空のまま出して添付付きで送ると、注意書きなしで閲覧注意だけを付ける。欄を閉じれば付けない。
    @Test func emptySpoilerFieldMarksMediaSensitive() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }
        model.showsSpoiler = true
        #expect(!model.isSensitive)

        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        #expect(model.isSensitive)
        await model.submit()
        #expect(sent.last?.sensitive == true)
        #expect(sent.last?.spoilerText == "")

        model.applyPickerSelection([try picked("b")])
        try await settle { isSettled(model) }
        #expect(!model.isSensitive)
        await model.submit()
        #expect(sent.last?.sensitive == false)
    }

    /// 既定で閲覧注意にする人は、最初の添付を足したときに注意書きの欄が開く。閉じたあとに足しても、開き直さない。
    @Test func defaultSensitiveOpensSpoilerOnFirstAttachment() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        model.apply(configuration: nil, defaultVisibility: nil, defaultSensitive: true)
        #expect(!model.showsSpoiler)

        model.applyPickerSelection([try picked("a")])
        #expect(model.showsSpoiler)
        #expect(model.isSensitive)

        model.showsSpoiler = false
        model.applyPickerSelection([try picked("a"), try picked("b")])
        #expect(!model.showsSpoiler)
        #expect(!model.isSensitive)
    }

    /// ログアウトなどで投稿欄の持ち主を閉じたら、読み込みやアップロードの途中の添付も止める。
    @Test func closingSessionCancelsUpload() async throws {
        let server = FakeServer()
        let session = TaskScope()
        let model = ComposeModel(tasks: session.child(), myAccountID: "1", media: server.service) { _ in }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        let photo = try picked("a")
        let loading = Gate()
        model.applyPickerSelection([
            PickedMedia(assetIdentifier: photo.assetIdentifier) { avoiding in
                try await loading.wait()
                return try await photo.load(avoiding)
            },
        ])
        try await settle { loading.waiterCount == 1 }

        session.close()
        try await settle { session.runningCount == 0 }

        #expect(loading.waiterCount == 0)
        #expect(server.uploads.isEmpty)
    }

    @Test func cannotPostUntilEveryUploadFinishes() async throws {
        let server = FakeServer()
        server.completesImmediately = false
        let model = makeModel(server)
        model.text = "見て"

        // 2枚は別々に読み込んで送るので、サーバーに届く順は決まっていない。後ろの1枚が先に届いても、選んだ1枚目の完了を待つ。
        let first = try picked("a")
        let arrivesLate = Gate()
        model.applyPickerSelection([
            PickedMedia(assetIdentifier: first.assetIdentifier) { avoiding in
                try await arrivesLate.wait()
                return try await first.load(avoiding)
            },
            try picked("b"),
        ])
        try await settle { server.pendingCount == 1 }
        arrivesLate.open()
        try await settle { server.pendingCount == 2 }
        #expect(!model.canPost)

        try server.finishUpload(named: "a.jpg", with: .success(Self.attachment(id: "1", processed: true)))
        try await settle { model.attachments.first?.serverID == "1" }
        #expect(!model.canPost)

        try server.finishUpload(named: "b.jpg", with: .success(Self.attachment(id: "2", processed: true)))
        try await settle { isSettled(model) }
        #expect(model.canPost)
    }

    /// 動画や大きな画像は、受け付けられた後にサーバーでの変換を待つ。
    @Test func waitsForProcessingWhenURLIsMissing() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in Self.attachment(id: "v1", processed: false) }
        let model = makeModel(server)

        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }

        #expect(server.waits == ["v1"])
        #expect(model.attachments.first?.isReady == true)
    }

    @Test func deselectingInPickerRemovesAttachmentAndFile() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        let a = try picked("a")
        let b = try picked("b")

        model.applyPickerSelection([a, b])
        try await settle { isSettled(model) }
        let file = try #require(model.attachments.first.flatMap { model.localMedia[$0.id]?.file })
        model.applyPickerSelection([b])

        #expect(model.attachedAssetIdentifiers == ["b"])
        #expect(!FileManager.default.fileExists(atPath: file.url.path()))
    }

    /// 投稿欄で外したものは、ピッカーが選んだままの選択を送り直してきても足し直さない。
    @Test func removedAttachmentIsNotReAddedByOpenPicker() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        let a = try picked("a")

        model.applyPickerSelection([a])
        try await settle { isSettled(model) }
        try model.removeAttachment(#require(model.attachments.first).id, pickerIsOpen: true)
        model.applyPickerSelection([a, try picked("b")])

        #expect(model.attachedAssetIdentifiers == ["b"])
    }

    /// ペーストしたメディアは、ピッカーで選んだものの後ろに足して送る。ピッカーの選択には入れない。
    @Test func pastedMediaIsAppendedAndUploaded() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }

        model.applyPickerSelection([try picked("a")])
        model.addPastedMedia([try pasted("p")])
        try await settle { isSettled(model) }
        await model.submit()

        #expect(sent.first?.mediaIDs == ["m-a.jpg", "m-p.jpg"])
    }

    /// ピッカーの選択が変わっても、ペーストしたメディアは外さない。ペーストした分だけ、ピッカーで選べる枚数を減らす。
    @Test func pastedMediaStaysWhenPickerSelectionChanges() async throws {
        let server = FakeServer()
        let model = makeModel(server)

        model.addPastedMedia([try pasted("p")])
        #expect(model.pickerSelectionLimit == 3)
        model.applyPickerSelection([try picked("a")])
        model.applyPickerSelection([])
        try await settle { isSettled(model) }

        #expect(model.attachments.count == 1)
        #expect(model.attachedAssetIdentifiers.isEmpty)
        #expect(model.pickerSelectionLimit == 3)
    }

    @Test func pastedMediaCanBeRemoved() async throws {
        let server = FakeServer()
        let model = makeModel(server)

        model.addPastedMedia([try pasted("p")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        let file = try #require(model.localMedia[id]?.file)
        model.removeAttachment(id, pickerIsOpen: false)

        #expect(model.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path()))
    }

    /// ペーストしたものは足す前から読み込んでいるので、アップロードが始まる前に外しても、読み込んだファイルを消す。
    @Test func removingPastedMediaBeforeUploadStartsDiscardsIt() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        var discarded = false
        var media = try pasted("p")
        media.discard = { discarded = true }

        model.addPastedMedia([media])
        model.removeAttachment(try #require(model.attachments.first?.id), pickerIsOpen: false)

        #expect(model.attachments.isEmpty)
        #expect(discarded)
    }

    /// 上限を超えた分は足さず、読み込んだファイルを消して、足さなかったものの種類を知らせる。
    @Test func pastingBeyondTheLimitAddsWhatFitsAndTellsTheRest() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        var skipped: [[MediaAttachment.Kind]] = []
        model.onPastedMediaSkipped = { skipped.append($0) }
        var discarded: [String] = []
        func discardable(_ name: String, kind: MediaAttachment.Kind = .image) throws -> PastedMedia {
            var media = try pasted(name, kind: kind)
            media.discard = { discarded.append(name) }
            return media
        }

        model.applyPickerSelection([try picked("a"), try picked("b"), try picked("c")])
        model.addPastedMedia([try discardable("p"), try discardable("q", kind: .video), try discardable("r")])
        try await settle { isSettled(model) }

        #expect(model.attachments.count == 4)
        #expect(server.uploads.map(\.filename).sorted() == ["a.jpg", "b.jpg", "c.jpg", "p.jpg"])
        #expect(skipped == [[.video, .image]])
        #expect(discarded == ["q", "r"])
    }

    /// ピッカーは上限まで埋まると開けないが、ペーストは受け付けて、入りきらない分を知らせる。サーバーの上限を読むまではどちらもできない。
    @Test func pasteIsAvailableEvenWhenAttachmentsAreFull() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        #expect(!model.canPasteMedia)
        model.apply(
            configuration: InstanceConfiguration(
                streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 1,
                mediaDescriptionLimit: 1500, supportedMediaTypes: ["image/jpeg"], mediaLimits: .unknown
            ),
            defaultVisibility: .public,
            defaultSensitive: nil
        )

        model.addPastedMedia([try pasted("p")])

        #expect(!model.canAttachMedia)
        #expect(model.canPasteMedia)
    }

    /// ペーストしたHEICを処理できないと500が返ったら、クリップボードから読み直さず、コピーしたファイルからJPEGを作って送り直す。
    @Test func resendsPastedHEICAsJPEGWithoutReloading() async throws {
        let server = FakeServer()
        server.uploadResult = { upload in
            guard upload.mimeType != "image/heic" else {
                throw MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media"))
            }
            return Self.attachment(id: "m-\(upload.filename)", processed: true)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let heic = folder.appending(path: "p.heic")
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.cgImage)
        let destination = try #require(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        var loads = 0
        let pasted = PastedMedia(kind: .image) {
            loads += 1
            return LocalMediaFile(url: heic, mimeType: "image/heic", kind: .image)
        }
        let model = makeModel(server)
        var reduced: [MediaAttachment.Kind] = []
        model.onMediaReduced = { reduced.append($0) }

        model.addPastedMedia([pasted])
        try await settleSlowly { isSettled(model) }

        #expect(server.uploads.map(\.mimeType) == ["image/heic", "image/jpeg"])
        #expect(loads == 1)
        // 大きさを変えずに形式だけを変えたので、縮めたとは知らせない。
        #expect(reduced.isEmpty)
        #expect(model.attachmentStatus(of: try #require(model.attachments.first?.id)) == .ready)
    }

    @Test func failedUploadKeepsReasonAndCanBeRetried() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in throw MediaUploadError.rejected(MastodonAPIError(statusCode: 422, message: "")) }
        let model = makeModel(server)
        model.text = "見て"

        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        #expect(model.attachments.first?.state == .failed(serverID: nil))
        #expect(model.localMedia[id]?.failure != nil)
        #expect(!model.canPost)

        server.uploadResult = { _ in Self.attachment(id: "1", processed: true) }
        model.retryAttachment(id)
        try await settle { isSettled(model) && model.attachments.first?.serverID == "1" }

        #expect(server.uploads.count == 2)
        #expect(model.localMedia[id]?.failure == nil)
        #expect(model.canPost)
    }

    /// サーバーが変換に失敗したら、同じ添付ファイルを待ち直しても終わらないので、再試行では送り直す。
    @Test func retryAfterProcessingFailureUploadsAgain() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in Self.attachment(id: "v1", processed: false) }
        server.waitResult = { _ in throw MediaUploadError.processingFailed(MastodonAPIError(statusCode: 422, message: "Error processing", serverMessage: "Error processing")) }
        let model = makeModel(server)

        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)

        server.uploadResult = { _ in Self.attachment(id: "v2", processed: true) }
        model.retryAttachment(id)
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.uploads.count == 2)
        #expect(server.waits == ["v1"])
    }

    /// 投稿を待つ間にピッカーで外したものは、投稿に失敗した後の下書きからも外れている。
    @Test func selectionChangedWhilePostingIsKept() async throws {
        let server = FakeServer()
        var release: CheckedContinuation<Void, Never>?
        let model = makeModel(server) { _ in
            await withCheckedContinuation { release = $0 }
            throw Failure()
        }
        let a = try picked("a")
        let b = try picked("b")
        model.applyPickerSelection([a, b])
        try await settle { isSettled(model) }

        let posting = Task { await model.submit() }
        try await settle { release != nil }
        model.applyPickerSelection([b])
        release?.resume()
        await posting.value

        #expect(model.attachedAssetIdentifiers == ["b"])
    }

    /// 投稿に失敗しても添付は残し、同じ添付のまま送り直すと同じIdempotency-Keyを使う。
    @Test func failedPostKeepsAttachmentsAndKey() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { draft in
            sent.append(draft)
            throw Failure()
        }

        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        await model.submit()
        await model.submit()
        model.applyPickerSelection([try picked("a"), try picked("b")])
        try await settle { isSettled(model) }
        await model.submit()

        #expect(model.attachments.count == 2)
        #expect(sent.count == 3)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        #expect(sent[1].idempotencyKey != sent[2].idempotencyKey)
        #expect(sent[2].mediaIDs == ["m-a.jpg", "m-b.jpg"])
    }

    /// アップロードの前に書いた代替テキストは、アップロードと一緒に送る。
    @Test func descriptionWrittenBeforeUploadIsSentWithUpload() async throws {
        let server = FakeServer()
        server.completesImmediately = false
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        let id = try #require(model.attachments.first?.id)
        model.setDescription("猫", of: id)
        try await settle { server.pendingCount == 1 }
        server.finishNextUpload(with: .success(Self.attachment(id: "1", processed: true, description: "猫")))
        try await settle { isSettled(model) }

        #expect(server.uploads.first?.description == "猫")
        #expect(server.descriptionUpdates.isEmpty)
        #expect(model.attachments.first?.isReady == true)
    }

    /// アップロードの途中に書いた代替テキストは、済んでから送る。済むまで投稿できない。
    @Test func descriptionWrittenDuringUploadIsSentAfterUpload() async throws {
        let server = FakeServer()
        server.completesImmediately = false
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        try await settle { server.pendingCount == 1 }
        let id = try #require(model.attachments.first?.id)

        model.setDescription("猫", of: id)
        server.finishNextUpload(with: .success(Self.attachment(id: "1", processed: true)))
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.uploads.first?.description == "")
        #expect(server.descriptionUpdates.map(\.description) == ["猫"])
        #expect(model.canPost)
    }

    @Test func descriptionWrittenAfterUploadIsSentAndBlocksPostingUntilDone() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)

        model.setDescription("猫", of: id)
        #expect(!model.canPost)
        #expect(model.attachmentStatus(of: id) == .sendingDescription)
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.descriptionUpdates.map(\.id) == ["m-a.jpg"])
        #expect(model.attachmentStatus(of: id) == .ready)
        #expect(model.canPost)
    }

    /// 代替テキストを送れなかったら理由を残し、再試行で送り直す。ファイルは送り直さない。
    @Test func failedDescriptionUpdateCanBeRetried() async throws {
        let server = FakeServer()
        server.descriptionResult = { _, _ in throw MastodonAPIError(statusCode: 500, message: "") }
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)

        model.setDescription("猫", of: id)
        try await settle { model.attachmentStatus(of: id) == .descriptionFailed }
        #expect(model.localMedia[id]?.descriptionFailure != nil)
        #expect(!model.canPost)

        server.descriptionResult = { id, description in Self.attachment(id: id, processed: true, description: description) }
        model.retryAttachment(id)
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.uploads.count == 1)
        #expect(server.descriptionUpdates.count == 2)
        #expect(model.localMedia[id]?.descriptionFailure == nil)
    }

    /// 送っている間に書き直したら、送り終えてから書き直した値を送る。
    @Test func descriptionChangedWhileSendingIsSentAgain() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)

        model.setDescription("猫", of: id)
        model.setDescription("黒猫", of: id)
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.descriptionUpdates.last?.description == "黒猫")
        #expect(model.attachments.first?.description == "黒猫")
    }

    /// 送っている間に元の値へ書き戻しても、送り終えるまでは投稿できない。送り終えたら、書き戻した値を送り直す。
    @Test func descriptionRevertedWhileSendingBlocksPostingUntilResent() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in Self.attachment(id: "1", processed: true, description: "猫") }
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        let id = try #require(model.attachments.first?.id)
        model.setDescription("猫", of: id)
        try await settle { model.attachments.first?.isReady == true }
        server.holdsDescriptionUpdates = true

        model.setDescription("黒猫", of: id)
        try await settle { server.pendingDescriptionCount == 1 }
        model.setDescription("猫", of: id)

        #expect(model.attachmentStatus(of: id) == .sendingDescription)
        #expect(!model.canPost)

        server.finishNextDescriptionUpdate()
        try await settle { server.pendingDescriptionCount == 1 }
        server.finishNextDescriptionUpdate()
        try await settle { model.attachmentStatus(of: id) == .ready }

        #expect(server.descriptionUpdates.map(\.description) == ["黒猫", "猫"])
        #expect(model.canPost)
    }

    /// サーバーが代替テキストを整えて返しても、書き直していなければ、返った値で済んだとみなして送り続けない。
    @Test func normalizedDescriptionFromServerIsAccepted() async throws {
        let server = FakeServer()
        server.descriptionResult = { id, description in
            Self.attachment(id: id, processed: true, description: description.trimmingCharacters(in: .whitespaces))
        }
        let model = makeModel(server)
        model.applyPickerSelection([try picked("a")])
        try await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)

        model.setDescription("猫 ", of: id)
        try await settle { model.attachments.first?.isReady == true }

        #expect(server.descriptionUpdates.count == 1)
        #expect(model.attachments.first?.description == "猫")
    }

    /// 並べ替えた順で投稿する。
    @Test func movedAttachmentsArePostedInNewOrder() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }
        model.applyPickerSelection([try picked("a"), try picked("b"), try picked("c")])
        try await settle { isSettled(model) }

        try model.moveAttachment(#require(model.attachments.last).id, to: 0)
        try model.moveAttachment(#require(model.attachments.last).id, to: 1)
        await model.submit()

        #expect(sent.first?.mediaIDs == ["m-c.jpg", "m-b.jpg", "m-a.jpg"])
    }

    /// 並べ替えた後にピッカーで足したものは後ろに付き、並べ替えた順は保たれる。
    @Test func pickerSelectionKeepsMovedOrder() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        let a = try picked("a")
        let b = try picked("b")
        model.applyPickerSelection([a, b])
        try model.moveAttachment(#require(model.attachments.last).id, to: 0)

        model.applyPickerSelection([a, b, try picked("c")])

        #expect(model.attachedAssetIdentifiers == ["b", "a", "c"])
    }

    /// 枚数の上限を読めるまでは、メディアを選ばせない。読めなかったときも、既定の4枚で選ばせない。
    @Test func pickerUsesServerAttachmentLimit() throws {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        #expect(!model.canAttachMedia)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        #expect(!model.canAttachMedia)

        model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 16, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: nil, defaultSensitive: nil)

        #expect(model.canAttachMedia)
        #expect(model.maxMediaAttachments == 16)
    }
}
