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
        model.setHomeHandlers(onRedraftDeleted: { homeDeleted.append($0) })
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

    // MARK: - アカウントを替えて画面を作り直したとき

    /// ウィンドウのアカウントを`server`のアカウントにしたときの送り先。送ったものを`posted`に`server:本文:返信先`で残す。
    private func home(_ id: String, myAccountID: String, uploads: Uploads, posted: Posted) -> ComposeAccount<Never> {
        ComposeAccount(id: id, myAccountID: myAccountID, media: uploads.service(server: "\(id).example")) { draft in
            posted.texts.withLock { $0.append("\(id):\(draft.text):\(draft.inReplyToID ?? "-")") }
        }
    }

    /// ウィンドウのアカウントで書いていた下書きは、ウィンドウのアカウントを切り替えると、切り替えた先のアカウントで書く形になる。
    /// 本文は残し、添付は切り替えた先のサーバーの上限を読んでからアップロードし直す。
    @Test func followsWindowAccountWhenSwitched() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "書きかけ"
        model.applyPickerSelection([try picked("p")])
        try await waitUntil { model.attachments.first?.serverID == "a.example-p.jpg" }

        let rebinding = model.rebind(home: home("b", myAccountID: "2", uploads: uploads, posted: posted), writing: home("a", myAccountID: "1", uploads: uploads, posted: posted))

        guard case .followed = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(model.otherAccount == nil)
        #expect(model.myAccountID == "2")
        #expect(model.text == "書きかけ")
        #expect(!model.canPost)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        try await waitUntil { model.attachments.first?.serverID == "b.example-p.jpg" }
        await model.submit()
        #expect(posted.texts.withLock { $0 } == ["b:書きかけ:-"])
    }

    /// 返信を書いていたら、切り替えた先のサーバーで返信先を探し直すまで、書いていたアカウントのまま残す。
    @Test func keepsWritingAccountUntilReplyTargetIsFound() throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.setReplyTarget(status(id: "10"))
        var changes: [String?] = []
        model.onAccountChange = { changes.append($0?.id) }

        let rebinding = model.rebind(home: home("b", myAccountID: "2", uploads: uploads, posted: posted), writing: home("a", myAccountID: "1", uploads: uploads, posted: posted))

        guard case .awaitingRetarget(let target, let isReply) = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(target.id == "10")
        #expect(isReply)
        #expect(model.otherAccount?.id == "a")
        #expect(model.replyTo?.id == "10")
        #expect(changes == ["a"])
    }

    /// 編集の途中は、切り替えた先では続けられないので、書いていたアカウントのまま残す。
    @Test func keepsWritingAccountWhileEditing() throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        #expect(model.beginEditing(status(id: "10", accountID: "1"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))

        let rebinding = model.rebind(home: home("b", myAccountID: "2", uploads: uploads, posted: posted), writing: home("a", myAccountID: "1", uploads: uploads, posted: posted))

        guard case .kept = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(model.otherAccount?.id == "a")
        #expect(model.editedStatus?.id == "10")
    }

    /// 「投稿するアカウント」で選んでいたアカウントは、ウィンドウを別のアカウントに切り替えても、選んだまま残す。
    /// 切り替えた先が選んでいたアカウントなら、ウィンドウのアカウントで書く形にし、同じサーバーなので添付はアップロードし直さない。
    @Test func keepsChosenAccountAndBecomesHomeWhenWindowSwitchesToIt() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.switchAccount(to: home("c", myAccountID: "3", uploads: uploads, posted: posted))
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil, accountID: "c")
        model.applyPickerSelection([try picked("p")])
        try await waitUntil { model.attachments.first?.serverID == "c.example-p.jpg" }

        let toB = model.rebind(home: home("b", myAccountID: "2", uploads: uploads, posted: posted), writing: home("c", myAccountID: "3", uploads: uploads, posted: posted))
        guard case .kept = toB else { Issue.record("\(toB)"); return }
        #expect(model.otherAccount?.id == "c")

        let toC = model.rebind(home: home("c", myAccountID: "3", uploads: uploads, posted: posted), writing: nil)
        guard case .kept = toC else { Issue.record("\(toC)"); return }
        #expect(model.otherAccount == nil)
        #expect(model.canPost)
        #expect(model.attachments.first?.serverID == "c.example-p.jpg")
        #expect(uploads.names.withLock { $0 } == ["c.example:p.jpg"])
    }

    /// 同じアカウントにログインし直したら、下書きも添付もそのまま、新しい送り先で送る。
    @Test func keepsDraftAndUsesNewTokenAfterLoggingInAgain() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.setReplyTarget(status(id: "10"))
        model.text += "了解"
        let renewed = ComposeAccount<Never>(id: "a", myAccountID: "1", media: uploads.service(server: "a.example")) { draft in
            posted.texts.withLock { $0.append("renewed:\(draft.inReplyToID ?? "-")") }
        }

        let rebinding = model.rebind(home: renewed, writing: nil)

        guard case .kept = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(model.replyTo?.id == "10")
        await model.submit()
        #expect(posted.texts.withLock { $0 } == ["renewed:10"])
    }

    /// 書いていたアカウントからログアウトしていたら、下書きを残してウィンドウのアカウントに戻す。返信先はそのサーバーでのIDなので外し、呼ぶ側が探し直せるよう返す。
    @Test func returnsToWindowAccountWhenWritingAccountIsLoggedOut() throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.switchAccount(to: home("c", myAccountID: "3", uploads: uploads, posted: posted))
        model.setReplyTarget(status(id: "10"))
        model.text += "了解"

        let rebinding = model.rebind(home: home("a", myAccountID: "1", uploads: uploads, posted: posted), writing: nil)

        guard case .returned(let dropped, let isReply) = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(dropped?.id == "10")
        #expect(isReply)
        #expect(model.otherAccount == nil)
        #expect(model.replyTo == nil)
        #expect(model.text.hasSuffix("了解"))
    }

    /// ログアウトしたアカウントの投稿の編集は、ウィンドウのアカウントでは続けられないので捨てる。
    @Test func discardsEditOfLoggedOutAccount() throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        let other = home("c", myAccountID: "3", uploads: uploads, posted: posted)
        #expect(model.beginEditing(status(id: "700", accountID: "3"), source: StatusSource(id: "700", text: "前の本文", spoilerText: ""), as: other))
        #expect(model.pointsToServerPost)

        let rebinding = model.rebind(home: home("a", myAccountID: "1", uploads: uploads, posted: posted), writing: nil)

        guard case .discarded = rebinding else { Issue.record("\(rebinding)"); return }
        #expect(model.editedStatus == nil)
        #expect(model.otherAccount == nil)
        #expect(!model.hasWrittenContent)
    }

    /// 送っている間にウィンドウのアカウントを切り替えても、送った結果は送り始めたアカウントに知らせる。切り替えた先の一覧に入れないため。
    @Test func reportsSubmissionToAccountThatStartedIt() async throws {
        let gate = Gate()
        var received: [String] = []
        let a = ComposeAccount<Never>(id: "a", myAccountID: "1", media: .unavailable, onSubmitted: { _ in received.append("a") }) { draft in
            try await gate.wait()
            return .stub(for: draft)
        }
        let model = ComposeModel(tasks: TaskScope(), home: a)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "Aの投稿"
        let sending = model.tasks.run(.action) { await model.submit() }
        try await waitUntil { gate.waiterCount >= 1 }

        let b = ComposeAccount<Never>(id: "b", myAccountID: "2", media: .unavailable, onSubmitted: { _ in received.append("b") }) { .stub(for: $0) }
        let rebuiltA = ComposeAccount<Never>(id: "a", myAccountID: "1", media: .unavailable, onSubmitted: { _ in received.append("rebuilt a") }) { .stub(for: $0) }
        model.rebind(home: b, writing: rebuiltA)
        gate.open()
        await sending?.value

        #expect(received == ["a"])
    }

    /// 添付の準備を待って送る途中に、書いていたアカウントからログアウトしたら、待つのをやめて下書きを残す。使う人が選んでいないウィンドウのアカウントで送らないため。
    @Test func stopsWaitingToPostWhenWritingAccountIsLoggedOut() async throws {
        let posted = Posted()
        let uploads = Uploads()
        let gate = Gate()
        let a = ComposeAccount<Never>(id: "a", myAccountID: "1", media: uploads.service(server: "a.example", gate: gate)) { draft in
            posted.texts.withLock { $0.append("a:\(draft.text)") }
        }
        let model = ComposeModel(tasks: TaskScope(), home: a)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "Aで送る投稿"
        model.applyPickerSelection([try picked("p")])
        try await waitUntil { gate.waiterCount >= 1 }
        let sending = model.tasks.run(.action) { await model.submit() }
        try await waitUntil { model.isWaitingForMedia }

        model.rebind(home: home("b", myAccountID: "2", uploads: uploads, posted: posted), writing: nil)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)
        gate.open()
        await sending?.value
        try await waitUntil { model.attachments.first?.serverID == "b.example-p.jpg" }

        #expect(posted.texts.withLock { $0 }.isEmpty)
        #expect(model.text == "Aで送る投稿")
    }

    /// ログアウトで外した返信先を探している間は投稿させない。見つかったら付け直し、下書きを捨てたら探していた返信先は付けない。
    @Test func holdsPostingUntilDroppedReplyTargetIsResolved() throws {
        let posted = Posted()
        let uploads = Uploads()
        let model = ComposeModel(tasks: TaskScope(), home: home("a", myAccountID: "1", uploads: uploads, posted: posted))
        model.switchAccount(to: home("c", myAccountID: "3", uploads: uploads, posted: posted))
        model.setReplyTarget(status(id: "10"))
        model.text += "了解"
        model.rebind(home: home("a", myAccountID: "1", uploads: uploads, posted: posted), writing: nil)
        model.apply(configuration: configuration, defaultVisibility: .public, defaultSensitive: nil)

        #expect(model.pendingRetarget?.status.id == "10")
        #expect(!model.canPost)
        model.resolvePendingRetarget(status(id: "20"))
        #expect(model.replyTo?.id == "20")
        #expect(model.canPost)

        model.switchAccount(to: home("c", myAccountID: "3", uploads: uploads, posted: posted))
        model.setReplyTarget(status(id: "30"))
        model.rebind(home: home("a", myAccountID: "1", uploads: uploads, posted: posted), writing: nil)
        model.reset()
        #expect(model.pendingRetarget == nil)
        model.resolvePendingRetarget(status(id: "40"))
        #expect(model.replyTo == nil)
    }

    /// 前の画面一式が読んでいたウィンドウのアカウントの上限と既定値は、切り替えたあとに届いても使わない。切り替えた先の既定の公開範囲を読む前に投稿させないため。
    @Test func ignoresDefaultsOfPreviousWindowAccount() async throws {
        let gate = Gate()
        let previous = AccountSession.testing(transport: RoutedTransport { _ in
            try await gate.wait()
            return (404, Data())
        })
        defer { previous.close() }
        let model = ComposeModel(tasks: TaskScope(), home: ComposeAccount(id: previous.credential.id, myAccountID: previous.credential.accountID, media: .unavailable) { .stub(for: $0) })
        model.text = "切り替えた先の既定値を読む前の投稿"
        let applying = previous.tasks.run(.action) { await previous.applyComposeDefaults(to: model) }
        try await waitUntil { gate.waiterCount >= 1 }
        previous.close()

        model.rebind(home: ComposeAccount(id: "b", myAccountID: "2", media: .unavailable) { .stub(for: $0) }, writing: ComposeAccount(id: previous.credential.id, myAccountID: previous.credential.accountID, media: .unavailable) { .stub(for: $0) })
        gate.open()
        await applying?.value

        #expect(model.writingAccountID == "b")
        #expect(!model.canPost)
    }
}
