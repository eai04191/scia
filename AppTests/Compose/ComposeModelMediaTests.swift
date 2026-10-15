import Foundation
import SciaCore
import Testing
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
        private var pendingUploads: [CheckedContinuation<MediaAttachment, any Error>] = []
        /// trueなら、アップロードを止めずにすぐ済ませる。
        var completesImmediately = true
        var uploadResult: (MediaUpload) throws -> MediaAttachment = { upload in
            attachment(id: "m-\(upload.filename)", processed: true)
        }
        var waitResult: (String) throws -> MediaAttachment = { id in attachment(id: id, processed: true) }

        var service: ComposeMediaService {
            ComposeMediaService(
                upload: { [self] upload in
                    uploads.append(upload)
                    if completesImmediately { return try uploadResult(upload) }
                    return try await withCheckedThrowingContinuation { pendingUploads.append($0) }
                },
                waitUntilProcessed: { [self] id in
                    waits.append(id)
                    return try waitResult(id)
                },
                makeThumbnail: { _ in nil }
            )
        }

        func finishNextUpload(with result: Result<MediaAttachment, any Error>) {
            pendingUploads.removeFirst().resume(with: result)
        }

        var pendingCount: Int { pendingUploads.count }
    }

    private static func attachment(id: String, processed: Bool) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: processed ? URL(string: "https://example.social/\(id).jpg") : nil, previewUrl: nil)
    }

    private func picked(_ id: String) throws -> PickedMedia {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ComposeModelMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return PickedMedia(assetIdentifier: id) { LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }
    }

    private func makeModel(_ server: FakeServer, post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(myAccountID: "1", media: server.service, post: post)
        model.apply(configuration: nil, defaultVisibility: .public)
        return model
    }

    /// 非同期のアップロードが進むまで待つ。
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
    }

    private func isSettled(_ model: ComposeModel) -> Bool {
        model.attachments.allSatisfy { attachment in
            switch attachment.state {
            case .uploaded, .failed: true
            case .uploading, .processing: false
            }
        }
    }

    @Test func postsMediaIDsInPickerOrderWithEmptyText() async throws {
        let server = FakeServer()
        var sent: [StatusDraft] = []
        let model = makeModel(server) { sent.append($0) }

        model.applyPickerSelection([try picked("b"), try picked("a")])
        await settle { isSettled(model) }
        await model.submit()

        #expect(sent.first?.mediaIDs == ["m-b.jpg", "m-a.jpg"])
        #expect(model.attachments.isEmpty)
    }

    @Test func cannotPostUntilEveryUploadFinishes() async throws {
        let server = FakeServer()
        server.completesImmediately = false
        let model = makeModel(server)
        model.text = "見て"

        model.applyPickerSelection([try picked("a"), try picked("b")])
        await settle { server.pendingCount == 2 }
        #expect(!model.canPost)

        server.finishNextUpload(with: .success(Self.attachment(id: "1", processed: true)))
        await settle { model.attachments.first?.serverID == "1" }
        #expect(!model.canPost)

        server.finishNextUpload(with: .success(Self.attachment(id: "2", processed: true)))
        await settle { isSettled(model) }
        #expect(model.canPost)
    }

    /// 動画や大きな画像は、受け付けられた後にサーバーでの変換を待つ。
    @Test func waitsForProcessingWhenURLIsMissing() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in Self.attachment(id: "v1", processed: false) }
        let model = makeModel(server)

        model.applyPickerSelection([try picked("a")])
        await settle { isSettled(model) }

        #expect(server.waits == ["v1"])
        #expect(model.attachments.first?.isReady == true)
    }

    @Test func deselectingInPickerRemovesAttachmentAndFile() async throws {
        let server = FakeServer()
        let model = makeModel(server)
        let a = try picked("a")
        let b = try picked("b")

        model.applyPickerSelection([a, b])
        await settle { isSettled(model) }
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
        await settle { isSettled(model) }
        try model.removeAttachment(#require(model.attachments.first).id, pickerIsOpen: true)
        model.applyPickerSelection([a, try picked("b")])

        #expect(model.attachedAssetIdentifiers == ["b"])
    }

    @Test func failedUploadKeepsReasonAndCanBeRetried() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in throw MediaUploadError.rejected(MastodonAPIError(statusCode: 422, message: "")) }
        let model = makeModel(server)
        model.text = "見て"

        model.applyPickerSelection([try picked("a")])
        await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        #expect(model.attachments.first?.state == .failed(serverID: nil))
        #expect(model.localMedia[id]?.failure != nil)
        #expect(!model.canPost)

        server.uploadResult = { _ in Self.attachment(id: "1", processed: true) }
        model.retryAttachment(id)
        await settle { isSettled(model) && model.attachments.first?.serverID == "1" }

        #expect(server.uploads.count == 2)
        #expect(model.localMedia[id]?.failure == nil)
        #expect(model.canPost)
    }

    /// 処理の待ち時間切れは、送り直さずに同じIDで待ち直す。
    @Test func retryAfterTimeoutWaitsAgainWithoutUploading() async throws {
        let server = FakeServer()
        server.uploadResult = { _ in Self.attachment(id: "v1", processed: false) }
        server.waitResult = { id in throw MediaUploadError.processingTimedOut(serverID: id) }
        let model = makeModel(server)

        model.applyPickerSelection([try picked("a")])
        await settle { isSettled(model) }
        let id = try #require(model.attachments.first?.id)
        #expect(model.attachments.first?.state == .failed(serverID: "v1"))

        server.waitResult = { id in Self.attachment(id: id, processed: true) }
        model.retryAttachment(id)
        await settle { model.attachments.first?.isReady == true }

        #expect(server.uploads.count == 1)
        #expect(server.waits == ["v1", "v1"])
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
        await settle { isSettled(model) }

        let posting = Task { await model.submit() }
        await settle { release != nil }
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
        await settle { isSettled(model) }
        await model.submit()
        await model.submit()
        model.applyPickerSelection([try picked("a"), try picked("b")])
        await settle { isSettled(model) }
        await model.submit()

        #expect(model.attachments.count == 2)
        #expect(sent.count == 3)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        #expect(sent[1].idempotencyKey != sent[2].idempotencyKey)
        #expect(sent[2].mediaIDs == ["m-a.jpg", "m-b.jpg"])
    }

    /// 枚数の上限を読めるまでは、メディアを選ばせない。読めなかったときも、既定の4枚で選ばせない。
    @Test func pickerUsesServerAttachmentLimit() throws {
        let model = ComposeModel(myAccountID: "1") { _ in }
        #expect(!model.canAttachMedia)
        model.apply(configuration: nil, defaultVisibility: .public)
        #expect(!model.canAttachMedia)

        model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 16, mediaDescriptionLimit: 1500, supportedMediaTypes: nil), defaultVisibility: nil)

        #expect(model.canAttachMedia)
        #expect(model.maxMediaAttachments == 16)
    }
}
