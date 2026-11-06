import CoreGraphics
import Foundation
import ImageIO
@testable import SciaCore
import SciaTesting
import Synchronization
import Testing
import UniformTypeIdentifiers

/// 投稿欄で書くアカウントを、ログインしているほかのアカウントに替える。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
@Suite(.scratch)
@MainActor
struct ComposeModelAccountTests {
    /// アップロードした添付のファイル名を、サーバーごとに覚える。`gate`を渡したサーバーは、開くまで応答を返さない。
    private final class Uploads: Sendable {
        let names = Mutex<[String]>([])

        func service(server: String, gate: Gate? = nil) -> ComposeMediaService {
            ComposeMediaService(
                upload: { [self] upload in
                    names.withLock { $0.append("\(server):\(upload.filename)") }
                    try await gate?.wait()
                    return MediaAttachment(id: "\(server)-\(upload.filename)", type: .image, url: URL(string: "https://\(server)/m.jpg"), previewUrl: nil)
                },
                waitUntilProcessed: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example/m.jpg"), previewUrl: nil) },
                updateDescription: { id, description in MediaAttachment(id: id, type: .image, url: URL(string: "https://example/m.jpg"), previewUrl: nil, description: description) },
                makeThumbnail: { _ in nil },
                unprocessableImageTypes: { [] },
                recordUnprocessableImageType: { _ in },
                preparation: { .keepsOriginal }
            )
        }
    }

    /// 送った投稿を、どのアカウントで送ったかと一緒に覚える。
    private final class Posted: Sendable {
        let texts = Mutex<[String]>([])
    }

    private let configuration = InstanceConfiguration(maxCharacters: 1000, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown)

    private func status(id: String, accountID: String = "2") -> Status {
        let author = Account(id: accountID, username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil)
        return Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: author, content: "", spoilerText: "", url: nil)
    }

    private func picked(_ id: String) throws -> PickedMedia {
        let folder = TestScratch.url("ComposeModelAccountTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jpg")
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return PickedMedia(assetIdentifier: id) { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }
    }

    private func other(_ uploads: Uploads, posted: Posted) -> ComposeAccount<Never> {
        ComposeAccount(id: "other", myAccountID: "50", media: uploads.service(server: "other.example")) { draft in
            posted.texts.withLock { $0.append("other:\(draft.text)") }
        }
    }

    /// 替えても本文は残し、返信先は前のサーバーでのIDなので外す。替えた先のサーバーの値を読むまで投稿させない。
    /// 読んだら、送るのも替えた先のアカウントで行い、送ったら今のアカウントに戻す。
    @Test func switchingKeepsTextAndPostsAsOtherAccount() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: uploads.service(server: "home.example")) { draft in
            posted.texts.withLock { $0.append("home:\(draft.text)") }
        }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        var changes: [String?] = []
        model.onAccountChange = { changes.append($0?.id) }
        model.setReplyTarget(status(id: "10"))
        model.text += "了解"

        #expect(model.switchAccount(to: other(uploads, posted: posted)))
        #expect(model.replyTo == nil)
        #expect(model.text == "了解")
        #expect(model.myAccountID == "50")
        #expect(!model.canPost)

        // 前のアカウントのサーバーの値が遅れて届いても、替えた先の下書きには使わない。
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        #expect(!model.canPost)
        model.apply(configuration: configuration, defaultVisibility: .unlisted, defaultSensitive: nil, accountID: "other")
        #expect(model.canPost)
        #expect(model.visibility == .unlisted)

        await model.submit()
        #expect(posted.texts.withLock { $0 } == ["other:了解"])
        #expect(model.otherAccount == nil)
        #expect(model.myAccountID == "1")
        #expect(changes == ["other", nil])
    }

    /// 添付は、替えた先のサーバーの上限を読んでから、そのサーバーへアップロードし直す。今のアカウントに戻したときも同じ。
    @Test func reuploadsAttachmentsAfterSwitching() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: uploads.service(server: "home.example")) { _ in }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.applyPickerSelection([try picked("a")])
        try await waitUntil { model.attachments.first?.serverID == "home.example-a.jpg" }

        model.switchAccount(to: other(uploads, posted: posted))
        #expect(model.attachments.first?.serverID == nil)
        #expect(uploads.names.withLock { $0 } == ["home.example:a.jpg"])
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, accountID: "other")
        try await waitUntil { model.attachments.first?.serverID == "other.example-a.jpg" }

        model.switchAccount(to: nil)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        try await waitUntil { model.attachments.first?.serverID == "home.example-a.jpg" }
        #expect(uploads.names.withLock { $0 } == ["home.example:a.jpg", "other.example:a.jpg", "home.example:a.jpg"])
    }

    /// 編集している間は、前のアカウントのサーバーの投稿を指しているので替えない。
    @Test func doesNotSwitchWhileEditing() throws {
        let posted = Posted()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        #expect(model.beginEditing(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))

        #expect(!model.switchAccount(to: other(Uploads(), posted: posted)))
        #expect(model.otherAccount == nil)
    }

    /// 替えた先のサーバーの値を読めなくても、前のサーバーの上限は使わず、読む前の上限にする。
    @Test func forgetsLimitsOfPreviousServer() {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: InstanceConfiguration(maxCharacters: 5000, charactersReservedPerURL: 23, maxMediaAttachments: 8, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)

        model.switchAccount(to: other(Uploads(), posted: Posted()))
        model.apply(configuration: nil, defaultVisibility: nil, defaultSensitive: nil, accountID: "other")

        #expect(model.maxCharacters == InstanceConfiguration.beforeLoading.maxCharacters)
        #expect(model.maxMediaAttachments == InstanceConfiguration.beforeLoading.maxMediaAttachments)
    }

    /// 今のアカウントの投稿の編集を始めたら、今のアカウントに戻す。ほかのアカウントのサーバーへ、今のアカウントの投稿のIDで送らないため。
    @Test func editingReturnsToHomeAccount() {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.switchAccount(to: other(Uploads(), posted: Posted()))

        #expect(model.beginEditing(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))
        #expect(model.otherAccount == nil)
    }

    /// 前のサーバーへのアップロードの途中で替えたら、その結果は使わず、抜けるのを待ってから替えた先のサーバーへ送り直す。
    @Test func ignoresUploadToPreviousServer() async throws {
        let uploads = Uploads()
        let gate = Gate()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: uploads.service(server: "home.example", gate: gate)) { _ in }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.applyPickerSelection([try picked("a")])
        try await waitUntil { uploads.names.withLock { $0 } == ["home.example:a.jpg"] }

        model.switchAccount(to: other(uploads, posted: Posted()))
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, accountID: "other")
        #expect(uploads.names.withLock { $0 } == ["home.example:a.jpg"])
        gate.open()
        try await waitUntil { model.attachments.first?.serverID != nil }

        #expect(model.attachments.first?.serverID == "other.example-a.jpg")
        #expect(uploads.names.withLock { $0 } == ["home.example:a.jpg", "other.example:a.jpg"])
    }

}
