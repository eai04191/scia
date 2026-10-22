import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

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
