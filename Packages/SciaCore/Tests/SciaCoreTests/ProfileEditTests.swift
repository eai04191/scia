import CoreGraphics
import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.requestPurpose(.action))
struct ProfileEditTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "14715",
                username: "alice"
            ),
            transport: transport
        )
    }

    private func source(note: String = "", fields: [ProfileSource.Field] = []) -> ProfileSource {
        ProfileSource(
            account: Account(id: "14715", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/avatars/alice.png")),
            note: note,
            fields: fields
        )
    }

    /// multipartの本文を、部分の名前と中身の組にする。画像の部分も文字として読める中身にして使う。
    private func parts(of request: URLRequest) throws -> [(name: String, value: String)] {
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "boundary=").last.map(String.init))
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        return body.components(separatedBy: "--\(boundary)").compactMap { part in
            guard let nameStart = part.range(of: "name=\""), let headerEnd = part.range(of: "\r\n\r\n") else { return nil }
            let name = part[nameStart.upperBound...].prefix { $0 != "\"" }
            // 部分の終わりの改行（Swiftでは1文字の"\r\n"）を除く。
            let value = part[headerEnd.upperBound...]
            return (String(name), String(value.hasSuffix("\r\n") ? value.dropLast() : value))
        }
    }

    // MARK: - 読み込み

    @Test func sourceReadsPlainTextNoteAndFields() async throws {
        let transport = StubTransport([try .fixture("verify_credentials")])

        let source = try await makeClient(transport).profileSource()

        #expect(source.account.displayName == "Alice")
        #expect(source.note == "テスト用のアカウント")
        #expect(source.fields == [])
        #expect(await transport.requests.first?.url?.path() == "/api/v1/accounts/verify_credentials")
    }

    /// Mastodonは、設定していない画像にも既定の画像のURLを返す。
    @Test func defaultImageCountsAsNotSet() async throws {
        let transport = StubTransport([try .fixture("verify_credentials")])

        let source = try await makeClient(transport).profileSource()

        #expect(source.hasAvatar)
        #expect(!source.hasHeader)
    }

    // MARK: - 保存

    @Test func saveSendsTextFieldsAndFlagsAsMultipart() async throws {
        let transport = StubTransport([try .fixture("verify_credentials")])
        var draft = ProfileDraft(source: source())
        draft.displayName = "アリス :blobcat:"
        draft.note = "1行目\n2行目"
        draft.fields = [ProfileFieldDraft(name: "Web", value: "https://example.com"), ProfileFieldDraft(), ProfileFieldDraft(name: "好き", value: "猫")]
        draft.locked = true

        _ = try await makeClient(transport).updateProfile(draft)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/api/v1/accounts/update_credentials")
        let sent = try parts(of: request)
        #expect(sent.map(\.name) == [
            "display_name", "note", "locked", "bot",
            "fields_attributes[0][name]", "fields_attributes[0][value]",
            "fields_attributes[1][name]", "fields_attributes[1][value]",
        ])
        #expect(sent.map(\.value) == ["アリス :blobcat:", "1行目\n2行目", "true", "false", "Web", "https://example.com", "好き", "猫"])
    }

    /// 補足情報を送らないとサーバーは変えないので、全部消したときは空の行を送る。
    @Test func removingAllFieldsSendsBlankField() async throws {
        let transport = StubTransport([try .fixture("verify_credentials")])
        var draft = ProfileDraft(source: source(fields: [ProfileSource.Field(name: "Web", value: "https://example.com")]))
        draft.fields = []

        _ = try await makeClient(transport).updateProfile(draft)

        let sent = try parts(of: try #require(await transport.requests.first))
        #expect(sent.filter { $0.name.hasPrefix("fields_attributes") }.map(\.value) == ["", ""])
    }

    @Test func replacedImageIsSentAsFile() async throws {
        let transport = StubTransport([try .fixture("verify_credentials")])
        var draft = ProfileDraft(source: source())
        draft.avatar = .replace(MediaUpload(data: Data("avatar-bytes".utf8), filename: "avatar.png", mimeType: "image/png"))

        _ = try await makeClient(transport).updateProfile(draft)

        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.png\"\r\nContent-Type: image/png\r\n\r\navatar-bytes"))
        #expect(!body.contains("name=\"header\""))
        #expect(await transport.requests.count == 1)
    }

    /// 画像を消すのは別のAPIなので、ほかの項目を保存してから消し、消したあとのプロフィールを返す。
    @Test func removedImageIsDeletedAfterSaving() async throws {
        let removed = #"{"id":"14715","username":"alice","acct":"alice","display_name":"Alice","locked":false,"bot":false,"note":"","url":"https://example.social/@alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","followers_count":0,"following_count":0,"statuses_count":0,"source":{"note":"消したあと","fields":[]},"emojis":[],"fields":[]}"#
        let transport = StubTransport([try .fixture("verify_credentials"), .json(removed, statusCode: 200)])
        var draft = ProfileDraft(source: source())
        draft.header = .remove

        let saved = try await makeClient(transport).updateProfile(draft)

        let requests = await transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["PATCH /api/v1/accounts/update_credentials", "DELETE /api/v1/profile/header"])
        #expect(saved.note == "消したあと")
    }

    // MARK: - 下書き

    @Test func blankFieldRowsAreNotChanges() {
        let original = source(fields: [ProfileSource.Field(name: "Web", value: "https://example.com")])
        var draft = ProfileDraft(source: original)
        #expect(!draft.hasChanges(from: original))

        draft.fields.append(ProfileFieldDraft())
        #expect(!draft.hasChanges(from: original))

        draft.fields[1].value = "猫"
        #expect(draft.hasChanges(from: original))
    }

    @Test func reorderingFieldsIsAChange() {
        let original = source(fields: [ProfileSource.Field(name: "A", value: "1"), ProfileSource.Field(name: "B", value: "2")])
        var draft = ProfileDraft(source: original)

        draft.fields.reverse()

        #expect(draft.hasChanges(from: original))
    }

    @Test func imageChangesAreChanges() {
        let original = source()
        var draft = ProfileDraft(source: original)

        draft.header = .remove

        #expect(draft.hasChanges(from: original))
    }

    @Test func problemsFollowLimits() {
        let limits = ProfileLimits(displayName: 3, note: 5, fields: 1, fieldName: 2, fieldValue: 2)
        var draft = ProfileDraft(source: source())
        draft.displayName = "あいう"
        draft.note = "12345"
        draft.fields = [ProfileFieldDraft(name: "ab", value: "cd")]
        #expect(draft.problems(limits: limits, charactersReservedPerURL: 23).isEmpty)

        draft.displayName = "あいうえ"
        draft.note = "123456"
        let tooLong = ProfileFieldDraft(name: "abc", value: "cde")
        let missingName = ProfileFieldDraft(name: " ", value: "猫")
        draft.fields = [tooLong, ProfileFieldDraft(), missingName]

        #expect(draft.problems(limits: limits, charactersReservedPerURL: 23) == [
            .displayNameTooLong,
            .noteTooLong,
            .tooManyFields,
            .fieldNameTooLong(tooLong.id),
            .fieldValueTooLong(tooLong.id),
            .fieldNameMissing(missingName.id),
        ])
    }

    /// 補足情報は、Mastodonが切り詰めるのと同じくコードポイントの数で数える。国旗の絵文字は1文字に見えても2つ数える。
    @Test func fieldCountsCodePoints() {
        let limits = ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255)
        let flags = ProfileFieldDraft(name: String(repeating: "🇯🇵", count: 128), value: String(repeating: "🇯🇵", count: 128))
        var draft = ProfileDraft(source: source())
        draft.fields = [flags]

        #expect(draft.problems(limits: limits, charactersReservedPerURL: 23) == [.fieldNameTooLong(flags.id), .fieldValueTooLong(flags.id)])
    }

    /// 自己紹介は投稿の本文と同じく、URLを決まった長さで数える。
    @Test func noteCountsURLsAsReservedLength() {
        var draft = ProfileDraft(source: source())
        draft.note = "https://example.com/a/very/long/path/that/is/longer/than/twenty/three"

        #expect(draft.noteLength(charactersReservedPerURL: 23) == 23)
    }

    /// 表示名は、Mastodonと同じくコードポイントの数で数える。
    @Test func displayNameCountsCodePoints() {
        var draft = ProfileDraft(source: source())
        draft.displayName = "👨‍👩‍👧"

        #expect(draft.displayNameLength == 5)
    }

    // MARK: - 編集画面の状態

    @MainActor
    @Test func editorStartsFromLoadedSource() async {
        let original = source(note: "元の自己紹介")
        let editor = ProfileEditor(api: ProfileEditor.API(source: { original }, save: { _ in original }))

        await editor.load()

        #expect(editor.draft?.note == "元の自己紹介")
        #expect(!editor.hasChanges)
        #expect(!editor.canSave)
    }

    @MainActor
    @Test func failedSaveKeepsDraft() async {
        struct Failure: Error {}
        let editor = ProfileEditor(api: ProfileEditor.API(source: { self.source() }, save: { _ in throw Failure() }))
        await editor.load()
        editor.draft?.note = "書きかけ"
        #expect(editor.canSave)

        await #expect(throws: Failure.self) { try await editor.save() }

        #expect(editor.draft?.note == "書きかけ")
        #expect(editor.hasChanges)
        #expect(!editor.isSaving)
    }

    @MainActor
    @Test func savedSourceBecomesNewOriginal() async throws {
        let saved = source(note: "保存した自己紹介")
        let editor = ProfileEditor(api: ProfileEditor.API(source: { self.source() }, save: { _ in saved }))
        await editor.load()
        editor.draft?.note = "保存した自己紹介"

        _ = try await editor.save()

        #expect(!editor.hasChanges)
    }

    @MainActor
    @Test func overLimitDraftCannotBeSaved() async {
        let editor = ProfileEditor(limits: ProfileLimits(displayName: 3, note: 500, fields: 4, fieldName: 255, fieldValue: 255), api: ProfileEditor.API(source: { self.source() }, save: { _ in self.source() }))
        await editor.load()

        editor.draft?.displayName = "長すぎる名前"

        #expect(editor.hasChanges)
        #expect(!editor.canSave)
    }

    // MARK: - 注目のハッシュタグと紹介しているユーザー

    /// サーバーの注目のハッシュタグと、送った操作を記録する。
    private actor FeaturedServer {
        var tags: [FeaturedTag]
        var endorsed: [String]
        private(set) var sent: [String] = []
        var failsFeature: String?
        private var nextID = 100

        init(tags: [FeaturedTag], endorsed: [String] = []) {
            self.tags = tags
            self.endorsed = endorsed
        }

        func feature(_ name: String) throws -> FeaturedTag {
            sent.append("feature:\(name)")
            if name == failsFeature { throw MastodonAPIError.from(statusCode: 422, body: Data(#"{"error":"Validation failed"}"#.utf8)) }
            nextID += 1
            let tag = FeaturedTag(id: "\(nextID)", name: name, statusesCount: 0)
            tags.append(tag)
            return tag
        }

        func unfeature(_ id: String) {
            sent.append("unfeature:\(id)")
            tags.removeAll { $0.id == id }
        }

        func endorse(_ id: String) {
            sent.append("endorse:\(id)")
            endorsed.append(id)
        }

        func unendorse(_ id: String) {
            sent.append("unendorse:\(id)")
            endorsed.removeAll { $0 == id }
        }

        func setFailsFeature(_ name: String?) { failsFeature = name }
        func setTags(_ tags: [FeaturedTag]) { self.tags = tags }
    }

    private func account(_ id: String) -> Account {
        Account(id: id, username: "u\(id)", acct: "u\(id)@remote.example", displayName: "U\(id)", avatar: nil)
    }

    @MainActor
    private func makeEditor(_ server: FeaturedServer, endorsements: [Account] = [], limits: ProfileLimits = .beforeMastodon46) -> ProfileEditor {
        let original = source()
        return ProfileEditor(limits: limits, api: ProfileEditor.API(
            source: { original },
            save: { _ in original },
            featuredTags: { await server.tags },
            featureTag: { try await server.feature($0) },
            unfeatureTag: { await server.unfeature($0) },
            endorsements: { endorsements },
            endorse: { await server.endorse($0) },
            unendorse: { await server.unendorse($0) }
        ))
    }

    /// 足すタグは、前の`#`と空白を除き、そろえた名前が同じタグは2つ目を足さない。並べ替えはないので、入れ替えただけでは変えたことにしない。
    @MainActor
    @Test func featuredTagNamesAreNormalizedAndDeduplicated() async {
        let server = FeaturedServer(tags: [FeaturedTag(id: "1", name: "Cat", statusesCount: 3)])
        let editor = makeEditor(server)
        await editor.loadAll()

        #expect(!editor.addFeaturedTag("#cat"))
        #expect(!editor.addFeaturedTag("  "))
        #expect(editor.addFeaturedTag(" #犬 "))
        #expect(editor.featuredTagNames == ["Cat", "犬"])
        #expect(editor.hasChanges)

        editor.removeFeaturedTag(at: 1)
        #expect(!editor.hasChanges)
    }

    /// 読めていない節は変えられない。
    @MainActor
    @Test func sectionCannotChangeUntilLoaded() async {
        struct Failure: Error {}
        let editor = ProfileEditor(api: ProfileEditor.API(source: { self.source() }, save: { _ in self.source() }, featuredTags: { throw Failure() }, endorsements: { throw Failure() }))
        await editor.loadAll()

        #expect(!editor.addFeaturedTag("cat"))
        #expect(!editor.addEndorsement(account("2")))
        #expect(editor.draft != nil)
    }

    /// 保存では、送る前に今のタグを読み直し、先に外してから足す。別の端末で足したタグは外し、同じタグは足し直さない。外すもの同士は並行に送るので、順は問わない。
    @MainActor
    @Test func saveRereadsTagsAndRemovesBeforeAdding() async throws {
        let server = FeaturedServer(tags: [FeaturedTag(id: "1", name: "猫", statusesCount: 3), FeaturedTag(id: "2", name: "犬", statusesCount: 1)])
        let editor = makeEditor(server)
        await editor.loadAll()
        editor.removeFeaturedTag(at: 1)
        editor.addFeaturedTag("鳥")
        // 開いたあとに、別の端末で「鳥」を足し、「魚」も足した。
        await server.setTags(await server.tags + [FeaturedTag(id: "3", name: "鳥", statusesCount: 0), FeaturedTag(id: "4", name: "魚", statusesCount: 0)])
        var changes = 0
        editor.onFeaturedChange = { changes += 1 }

        _ = try await editor.save()

        #expect(await server.sent.sorted() == ["unfeature:2", "unfeature:4"])
        #expect(await server.tags.map(\.name) == ["猫", "鳥"])
        #expect(!editor.hasChanges)
        #expect(changes == 1)
    }

    /// 送れないものがあれば投げ、送れた分は元の値に取り込む。送り直すときは残りだけを送る。足すのは外し終えてからで、足すもの同士は並行に送る。
    @MainActor
    @Test func failedTagSaveKeepsRemainderForRetry() async throws {
        let server = FeaturedServer(tags: [FeaturedTag(id: "1", name: "猫", statusesCount: 3)])
        let editor = makeEditor(server)
        await editor.loadAll()
        editor.removeFeaturedTag(at: 0)
        editor.addFeaturedTag("鳥")
        editor.addFeaturedTag("魚")
        await server.setFailsFeature("魚")
        var changes = 0
        editor.onFeaturedChange = { changes += 1 }

        await #expect(throws: MastodonAPIError.self) { try await editor.save() }

        #expect(await server.sent.first == "unfeature:1")
        #expect(await server.sent.dropFirst().sorted() == ["feature:魚", "feature:鳥"].sorted())
        #expect(editor.featuredTagNames == ["鳥", "魚"])
        #expect(editor.hasChanges)
        #expect(changes == 1)

        await server.setFailsFeature(nil)
        _ = try await editor.save()

        #expect(await server.sent.suffix(1) == ["feature:魚"])
        #expect(!editor.hasChanges)
    }

    /// プロフィールの項目を保存できたあとにタグを送れなくても、保存できたプロフィールを知らせる。開いている自分のプロフィールに反映するため。
    /// 1件も送れなかったときは、注目のハッシュタグを変えたことにしない。
    @MainActor
    @Test func profileSavedIsReportedEvenWhenTagsFail() async throws {
        let server = FeaturedServer(tags: [])
        let editor = makeEditor(server)
        await editor.loadAll()
        editor.draft?.note = "書き換えた"
        editor.addFeaturedTag("魚")
        await server.setFailsFeature("魚")
        var savedNotes: [String] = []
        var changes = 0
        editor.onProfileSaved = { savedNotes.append($0.note) }
        editor.onFeaturedChange = { changes += 1 }

        await #expect(throws: MastodonAPIError.self) { try await editor.save() }

        #expect(savedNotes.count == 1)
        #expect(changes == 0)
        #expect(editor.hasChanges)
    }

    /// プロフィールの項目、注目のハッシュタグ、紹介しているユーザーは、前のものの応答を待たずに並行に送る。
    @MainActor
    @Test func saveSendsProfileTagsAndEndorsementsConcurrently() async throws {
        let server = FeaturedServer(tags: [])
        let profileGate = Gate()
        let original = source()
        let editor = ProfileEditor(limits: .beforeMastodon46, api: ProfileEditor.API(
            source: { original },
            save: { _ in
                try await profileGate.wait()
                return original
            },
            featuredTags: { await server.tags },
            featureTag: { try await server.feature($0) },
            unfeatureTag: { await server.unfeature($0) },
            endorsements: { [] },
            endorse: { await server.endorse($0) },
            unendorse: { await server.unendorse($0) }
        ))
        await editor.loadAll()
        editor.draft?.note = "書き換えた"
        editor.addFeaturedTag("猫")
        #expect(editor.addEndorsement(account("3")))

        let saving = Task { try await editor.save() }
        // プロフィールの項目の応答が届かない間に、ほかの2つを送り終える。
        try await waitUntil { await server.sent.count >= 2 && profileGate.waiterCount >= 1 }
        #expect(await server.sent.sorted() == ["endorse:3", "feature:猫"])
        #expect(editor.isSaving)

        profileGate.open()
        _ = try await saving.value
        #expect(!editor.hasChanges)
    }

    /// プロフィールの項目を送れなくても、注目のハッシュタグは送り終え、送れた分を取り込む。
    @MainActor
    @Test func failedProfileSaveStillSendsTags() async throws {
        struct Failure: Error {}
        let server = FeaturedServer(tags: [])
        let original = source()
        let editor = ProfileEditor(limits: .beforeMastodon46, api: ProfileEditor.API(
            source: { original },
            save: { _ in throw Failure() },
            featuredTags: { await server.tags },
            featureTag: { try await server.feature($0) },
            unfeatureTag: { await server.unfeature($0) }
        ))
        await editor.loadAll()
        editor.draft?.note = "書き換えた"
        editor.addFeaturedTag("猫")
        var changes = 0
        editor.onFeaturedChange = { changes += 1 }

        await #expect(throws: Failure.self) { try await editor.save() }

        #expect(await server.sent == ["feature:猫"])
        #expect(!editor.featuredTagsChanged)
        #expect(editor.hasChanges)
        #expect(changes == 1)
    }

    /// 読めなかった節は、読み直して読めたら変えられるようになる。
    @MainActor
    @Test func failedSectionCanBeReloaded() async {
        struct Failure: Error {}
        let fails = Mutex(true)
        let editor = ProfileEditor(api: ProfileEditor.API(
            source: { self.source() },
            save: { _ in self.source() },
            featuredTags: {
                if fails.withLock({ $0 }) { throw Failure() }
                return [FeaturedTag(id: "1", name: "猫", statusesCount: 3)]
            }
        ))
        await editor.loadAll()
        #expect(editor.featuredTagsSource.value == nil)

        fails.withLock { $0 = false }
        await editor.loadFeaturedTags()

        #expect(editor.featuredTagNames == ["猫"])
        #expect(editor.addFeaturedTag("犬"))
    }

    /// 紹介は、元の値と比べて、外すものと足すものを並行に送る。
    @MainActor
    @Test func saveEndorsementsRemovesAndAdds() async throws {
        let server = FeaturedServer(tags: [], endorsed: ["2"])
        let editor = makeEditor(server, endorsements: [account("2")])
        await editor.loadAll()
        editor.removeEndorsement(at: 0)
        #expect(editor.addEndorsement(account("3")))
        #expect(!editor.addEndorsement(account("3")))

        _ = try await editor.save()

        #expect(await server.sent.sorted() == ["endorse:3", "unendorse:2"])
        #expect(!editor.hasChanges)
    }

    /// 注目のハッシュタグが上限を超えたら保存させない。上限が分からなければ止めない。
    @MainActor
    @Test func tooManyFeaturedTagsCannotBeSaved() async {
        let limited = ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255, featuredTags: 1)
        let editor = makeEditor(FeaturedServer(tags: [FeaturedTag(id: "1", name: "猫", statusesCount: 3)]), limits: limited)
        await editor.loadAll()
        editor.addFeaturedTag("犬")

        #expect(editor.hasTooManyFeaturedTags)
        #expect(!editor.canSave)

        let unlimited = makeEditor(FeaturedServer(tags: [FeaturedTag(id: "1", name: "猫", statusesCount: 3)]))
        await unlimited.loadAll()
        unlimited.addFeaturedTag("犬")
        #expect(unlimited.canSave)
    }

    // MARK: - 切り抜き

    @Test func minimumZoomFillsFrame() {
        #expect(ProfileImageCrop.minimumZoomScale(imageSize: CGSize(width: 2000, height: 1000), frameSize: CGSize(width: 300, height: 300)) == 0.3)
        #expect(ProfileImageCrop.minimumZoomScale(imageSize: CGSize(width: 1000, height: 2000), frameSize: CGSize(width: 360, height: 120)) == 0.36)
    }

    @Test func cropRectFollowsOffsetAndZoom() {
        let rect = ProfileImageCrop.avatar.cropRect(
            imageSize: CGSize(width: 2000, height: 1000),
            frameSize: CGSize(width: 300, height: 300),
            contentOffset: CGPoint(x: 150, y: 0),
            zoomScale: 0.3
        )

        #expect(rect == CGRect(x: 500, y: 0, width: 1000, height: 1000))
    }

    /// 端まで引っぱったときなど、枠が画像の外にはみ出していても、画像の中に収める。
    @Test func cropRectStaysInsideImage() {
        let rect = ProfileImageCrop.header(.wide).cropRect(
            imageSize: CGSize(width: 1200, height: 900),
            frameSize: CGSize(width: 360, height: 120),
            contentOffset: CGPoint(x: -40, y: 400),
            zoomScale: 0.3
        )

        #expect(rect == CGRect(x: 0, y: 500, width: 1200, height: 400))
    }

    @Test func standardHeaderCropIsThreeByTwo() {
        let rect = ProfileImageCrop.header(.standard).cropRect(
            imageSize: CGSize(width: 1200, height: 1200),
            frameSize: CGSize(width: 360, height: 240),
            contentOffset: CGPoint(x: 0, y: 60),
            zoomScale: 0.3
        )

        #expect(ProfileImageCrop.HeaderAspect.allCases.first == .standard)
        #expect(rect == CGRect(x: 0, y: 200, width: 1200, height: 800))
    }

    @Test func outputIsScaledDownToServerSize() {
        #expect(ProfileImageCrop.avatar.outputSize(for: CGSize(width: 1000, height: 1000)) == CGSize(width: 400, height: 400))
        #expect(ProfileImageCrop.header(.wide).outputSize(for: CGSize(width: 3000, height: 1000)) == CGSize(width: 1500, height: 500))
        #expect(ProfileImageCrop.avatar.outputSize(for: CGSize(width: 200, height: 200)) == CGSize(width: 200, height: 200))
    }

    /// Mastodonはヘッダー画像を、1500×500と同じ画素数に収まるまで縮める。3:2なら1500×500の枠ではなく、同じ画素数の大きさまで送る。
    @Test func standardHeaderOutputKeepsServerPixelCount() {
        let output = ProfileImageCrop.header(.standard).outputSize(for: CGSize(width: 3000, height: 2000))

        #expect(output == CGSize(width: 1060, height: 707))
        #expect(output.width * output.height <= 1500 * 500)
    }
}
