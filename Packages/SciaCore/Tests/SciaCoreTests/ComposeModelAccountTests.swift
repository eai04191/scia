import CoreGraphics
import Foundation
import ImageIO
@testable import SciaCore
import SciaTesting
import Synchronization
import Testing
import UniformTypeIdentifiers

/// 投稿欄で投稿するアカウントを、ログインしているほかのアカウントに替える。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
@Suite(.scratch)
@MainActor
struct ComposeModelAccountTests {
    /// アップロードした添付のファイル名を、サーバーごとに覚える。`gate`を渡したサーバーは、開くまで応答を返さない。
    private final class Uploads: Sendable {
        let names = Mutex<[String]>([])

        /// - Parameter gatedFilename: 渡すと、その名前のファイルだけを`gate`で待たせる。
        func service(server: String, gate: Gate? = nil, gatedFilename: String? = nil) -> ComposeMediaService {
            ComposeMediaService(
                upload: { [self] upload in
                    names.withLock { $0.append("\(server):\(upload.filename)") }
                    if gatedFilename == nil || gatedFilename == upload.filename {
                        try await gate?.wait()
                    }
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

    /// メンションを入れる前の準備は、同じアカウントのままなら替えないので、編集と書き直しの途中でも通す。ほかのアカウントへは替えない。
    @Test func preparesInsertionWhileEditingOrRedraftingWithSameAccount() throws {
        let posted = Posted()
        let editing = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        #expect(editing.beginEditing(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))
        #expect(editing.prepareInsertion(as: nil))
        #expect(editing.editedStatus?.id == "10")
        #expect(!editing.prepareInsertion(as: other(Uploads(), posted: posted)))
        #expect(editing.otherAccount == nil)

        let redrafting = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        #expect(redrafting.beginRedrafting(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))
        #expect(redrafting.prepareInsertion(as: nil))
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


    /// ほかのアカウントの投稿の編集は、投稿するアカウントをそのアカウントにして始め、そのアカウントの送り先で送る。送ったら今のアカウントに戻す。
    @Test func editsOtherAccountsStatus() async throws {
        let posted = Posted()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { draft in
            posted.texts.withLock { $0.append("home:\(draft.text)") }
        }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        let other = ComposeAccount<Never>(id: "other", myAccountID: "50", media: .unavailable) { draft in
            posted.texts.withLock { $0.append("other:\(draft.editing?.statusID ?? "new"):\(draft.text)") }
        }

        #expect(model.beginEditing(status(id: "700", accountID: "50"), source: StatusSource(id: "700", text: "前の本文", spoilerText: ""), as: other))
        #expect(model.otherAccount?.id == "other")
        model.text = "直した本文"
        await model.submit()

        #expect(posted.texts.withLock { $0 } == ["other:700:直した本文"])
        #expect(model.otherAccount == nil)
    }

    /// ほかのアカウントの投稿を削除して書き直すときは、そのアカウントのサーバーで元の投稿を消し、消せたことはそのアカウントに知らせる。今のアカウントには知らせない。
    /// 今のアカウントで同じIDの投稿が消えたという知らせは、別の投稿なので使わない。
    @Test func redraftsOtherAccountsStatus() async throws {
        let deleted = Posted()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        var homeDeleted: [String] = []
        model.onRedraftDeleted = { homeDeleted.append($0) }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        let redraft = ComposeRedraftService(
            deleteStatus: { id in deleted.texts.withLock { $0.append("delete:\(id)") } },
            waitUntilReleased: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example/m.jpg"), previewUrl: nil) }
        )
        let other = ComposeAccount<Never>(id: "other", myAccountID: "50", media: .unavailable, redraft: redraft, onRedraftDeleted: { id in
            deleted.texts.withLock { $0.append("forget:\(id)") }
        }) { draft in
            deleted.texts.withLock { $0.append("post:\(draft.text)") }
        }

        #expect(model.beginRedrafting(status(id: "700", accountID: "50"), source: StatusSource(id: "700", text: "前の本文", spoilerText: ""), as: other))
        model.redraftedStatusWasDeleted("700", stopsRedrafting: true)
        #expect(model.redraft != nil)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, accountID: "other")
        await model.submit()

        #expect(deleted.texts.withLock { $0 } == ["delete:700", "forget:700", "post:前の本文"])
        #expect(homeDeleted.isEmpty)
    }

    /// ほかのアカウントの投稿を書き直すときは、投票の締め切りを、そのアカウントのサーバーの上限で決める。
    /// 今のアカウントのサーバーの上限や、読む前の上限で決めると、そのサーバーで選べない締め切りになり、送れないため。
    @Test func redraftsPollWithinOtherAccountsLimits() throws {
        let limits = PollLimits(maxOptions: 4, maxCharactersPerOption: 50, expirationRange: 300...1500)
        let otherConfiguration = InstanceConfiguration(maxCharacters: 1000, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, pollLimits: limits, mediaLimits: .unknown)
        let author = Account(id: "50", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let poll = Poll(id: "p", expiresAt: created.addingTimeInterval(1500), expired: false, multiple: false, votesCount: 0, options: [.init(title: "a", votesCount: 0), .init(title: "b", votesCount: 0)])
        let original = Status(id: "700", createdAt: created, account: author, content: "", spoilerText: "", url: nil, poll: poll)
        let source = StatusSource(id: "700", text: "本文", spoilerText: "")
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        let other = ComposeAccount<Never>(id: "other", myAccountID: "50", media: .unavailable) { _ in }

        #expect(model.beginRedrafting(original, source: source, as: other, configuration: otherConfiguration))

        #expect(model.poll?.expiresIn == StatusDraft.redraft(of: original, source: source, pollLimits: limits).poll?.expiresIn)
        #expect(model.pollLimits == limits)
    }

    // MARK: - 同じアカウントにログインし直したあとの引き継ぎ

    /// 同じアカウントにログインし直して画面を作り直しても、書いた本文、注意書き、返信先、選んだ公開範囲と言語を残し、新しい画面の送り先で送る。
    /// 上限と既定値は新しい画面で読み直す。読み直しても、選んだ公開範囲と言語は上書きしない。
    @Test func adoptsDraftAfterLoggingInAgain() async throws {
        let posted = Posted()
        let previous = ComposeModel(tasks: TaskScope(), myAccountID: "1") { draft in
            posted.texts.withLock { $0.append("previous:\(draft.text)") }
        }
        previous.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        previous.setReplyTarget(status(id: "10"))
        previous.text += "了解"
        previous.showsSpoiler = true
        previous.spoilerText = "注意"
        previous.choose(.unlisted)
        previous.choose(language: "en")
        let text = previous.text

        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1") { draft in
            posted.texts.withLock { $0.append("renewed:\(draft.text):\(draft.inReplyToID ?? "-")") }
        }
        renewed.adoptDraft(from: previous, otherAccount: nil)

        #expect(renewed.text == text)
        #expect(renewed.spoilerText == "注意")
        #expect(renewed.showsSpoiler)
        #expect(renewed.replyTo?.id == "10")
        #expect(renewed.hasWrittenContent)

        renewed.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, defaultLanguage: "ja")
        #expect(renewed.visibility == .unlisted)
        #expect(renewed.language == "en")
        await renewed.submit()
        #expect(posted.texts.withLock { $0 } == ["renewed:\(text):10"])
    }

    /// アップロードが済んだ添付は、同じアカウントのメディアなので、送り直さずに使う。済んでいない添付は、新しい画面で上限を読んでから送り直す。
    /// 前の画面の送りかけは、前の画面を止めたあとに応答が届いても、引き継いだ下書きを書き換えない。
    @Test func keepsUploadedAttachmentsAndReuploadsUnfinishedOnesAfterLoggingInAgain() async throws {
        let previousUploads = Uploads()
        let renewedUploads = Uploads()
        let gate = Gate()
        let previousTasks = TaskScope()
        let previous = ComposeModel(tasks: previousTasks, myAccountID: "1", media: previousUploads.service(server: "previous.example", gate: gate, gatedFilename: "b.jpg")) { _ in }
        previous.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        previous.applyPickerSelection([try picked("a"), try picked("b")])
        try await waitUntil {
            previous.attachments.first?.serverID == "previous.example-a.jpg" && previousUploads.names.withLock { $0.contains("previous.example:b.jpg") }
        }

        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: renewedUploads.service(server: "renewed.example")) { _ in }
        renewed.adoptDraft(from: previous, otherAccount: nil)
        previousTasks.close()
        gate.open()

        #expect(renewed.attachments.map(\.serverID) == ["previous.example-a.jpg", nil])
        #expect(previous.attachments.isEmpty)
        renewed.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        try await waitUntil { renewed.attachments.last?.serverID == "renewed.example-b.jpg" }
        #expect(renewed.attachments.first?.serverID == "previous.example-a.jpg")
        #expect(renewedUploads.names.withLock { $0 } == ["renewed.example:b.jpg"])
    }

    /// 編集の途中でログインし直しても、編集している投稿を引き継ぐ。
    @Test func adoptsEditAfterLoggingInAgain() throws {
        let previous = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        #expect(previous.beginEditing(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))
        previous.text = "直した本文"

        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        renewed.adoptDraft(from: previous, otherAccount: nil)

        #expect(renewed.editedStatus?.id == "10")
        #expect(renewed.text == "直した本文")
    }

    /// ほかのアカウントで書いている途中にログインし直しても、そのアカウントで書いたままにする。
    @Test func adoptsOtherAccountAfterLoggingInAgain() async throws {
        let posted = Posted()
        let previous = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        previous.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        previous.switchAccount(to: other(Uploads(), posted: posted))
        previous.text = "別のアカウントから"

        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1") { draft in
            posted.texts.withLock { $0.append("home:\(draft.text)") }
        }
        var changes: [String?] = []
        renewed.onAccountChange = { changes.append($0?.id) }
        renewed.adoptDraft(from: previous, otherAccount: other(Uploads(), posted: posted))

        #expect(renewed.myAccountID == "50")
        #expect(changes == ["other"])
        renewed.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, accountID: "other")
        await renewed.submit()
        #expect(posted.texts.withLock { $0 } == ["other:別のアカウントから"])
    }

    /// 代替テキストを送っている途中にログインし直しても、新しい画面で送り直す。送り直さないと、送り終えるのを待つ投稿が進まなくなるため。
    @Test func resendsPendingDescriptionAfterLoggingInAgain() async throws {
        let media = MediaAttachment(id: "m1", type: .image, url: URL(string: "https://home.example/m.jpg"), previewUrl: nil)
        let gate = Gate()
        var previousService = ComposeMediaService.unavailable
        previousService.updateDescription = { id, description in
            try await gate.wait()
            return MediaAttachment(id: id, type: .image, url: media.url, previewUrl: nil, description: description)
        }
        let previousTasks = TaskScope()
        let previous = ComposeModel(tasks: previousTasks, myAccountID: "1", media: previousService) { _ in }
        let scheduled = ScheduledStatus(id: "s1", scheduledAt: Date(timeIntervalSince1970: 2_000_000_000), params: .init(text: "予約", mediaIDs: ["m1"]), mediaAttachments: [media])
        #expect(previous.beginRewriting(scheduled))
        previous.setDescription("書いた代替テキスト", of: try #require(previous.attachments.first?.id))
        try await waitUntil { gate.waiterCount == 1 }

        let sent = Mutex<[String]>([])
        var renewedService = ComposeMediaService.unavailable
        renewedService.updateDescription = { id, description in
            sent.withLock { $0.append(description) }
            return MediaAttachment(id: id, type: .image, url: media.url, previewUrl: nil, description: description)
        }
        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: renewedService) { _ in }
        renewed.adoptDraft(from: previous, otherAccount: nil)
        previousTasks.close()

        try await waitUntil { renewed.isMediaReady }
        #expect(sent.withLock { $0 } == ["書いた代替テキスト"])
    }

    /// ペーストや共有で足したメディアを読み込んでいる途中にログインし直しても、読み込んだファイルを前の画面の処理が消さず、新しい画面で送る。
    /// 読み込みは1回きりで、新しい画面も同じ読み込みの結果を使うため。
    @Test func keepsFileStillLoadingWhenLoggingInAgain() async throws {
        let file = try picked("pasted")
        let loaded = try await file.load([])
        let gate = Gate()
        // アプリのペーストと共有の読み込みは、始めた1つの読み込みの結果を何度でも返す。
        let loading = Task {
            try await gate.wait()
            return loaded
        }
        let previousTasks = TaskScope()
        let previous = ComposeModel(tasks: previousTasks, myAccountID: "1") { _ in }
        previous.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        previous.addPastedMedia([PastedMedia(kind: .image, load: { try await loading.value })])
        try await waitUntil { gate.waiterCount == 1 }

        let uploads = Uploads()
        let renewed = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: uploads.service(server: "renewed.example")) { _ in }
        renewed.adoptDraft(from: previous, otherAccount: nil)
        previousTasks.close()
        gate.open()
        await previousTasks.waitForRunning()

        #expect(FileManager.default.fileExists(atPath: loaded.url.path))
        renewed.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        try await waitUntil { renewed.isMediaReady }
        #expect(uploads.names.withLock { $0 } == ["renewed.example:pasted.jpg"])
    }
}
