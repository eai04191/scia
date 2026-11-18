import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// セッションが持つ部品と、使い始めるときの手順。UIごとに作ったり呼んだりしなくても、同じものが同じ順で動くことを確かめる。
@Suite(.scratch)
@MainActor
struct AccountSessionStoresTests {
    private final class EchoTranslator: StatusTranslating {
        let targets = Mutex<[String]>([])

        func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart] {
            targets.withLock { $0.append(target) }
            return parts
        }
    }

    nonisolated private static let instance = Data(#"{"version":"4.7.3","configuration":{"urls":{"streaming":"wss://streaming.example.social"}}}"#.utf8)
    nonisolated private static let preferences = Data(#"{"posting:default:visibility":"public","posting:default:sensitive":false,"posting:default:language":null,"reading:expand:spoilers":false,"reading:autoplay:gifs":true}"#.utf8)

    private func transport() -> RoutedTransport {
        RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v2/instance": (200, Self.instance)
            case "/api/v1/preferences": (200, Self.preferences)
            default: (404, Data())
            }
        }
    }

    private func status(language: String) -> Status {
        Status(id: "1", createdAt: Date(timeIntervalSince1970: 0), account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil), content: "<p>Hello</p>", spoilerText: "", language: language, url: nil)
    }

    /// 使い始めるだけでは通信しない。サーバーの情報は、最初のタイムラインを読み終えてから`loadServerInfo()`で読むため。
    @Test func startSendsNoRequests() async throws {
        let transport = transport()
        let session = AccountSession.testing(transport: transport)
        defer { session.close() }

        session.start { 0 }
        // 走っているのは、レート制限が明けたときと電波が戻ったときの、やり直しの見張りの2つだけ。どちらも閉じるまで走り続けるので、終わりは待たない。
        #expect(session.tasks.runningCount == 2)
        #expect(transport.requests.isEmpty)

        session.loadServerInfo()
        try await waitUntil { session.diagnostics.serverVersion != nil }
        #expect(!transport.requests.isEmpty)
    }

    /// 使い始めてサーバーの情報を読むと、サーバーの版を接続の状態に入れ、アカウントの設定を読んで、アニメーションを再生するかを設定に覚えさせる。
    @Test func startLoadsServerVersionAndRemembersServerAnimations() async throws {
        let defaults = TestScratch.defaults("AccountSessionStoresTests.start")
        let settings = AppSettings(defaults: defaults)
        let session = AccountSession.testing(transport: transport(), settings: settings, defaults: defaults)
        defer { session.close() }
        var loaded: ServerPreferences?
        session.onPreferencesLoad = { loaded = $0 }

        session.start { 0 }
        session.loadServerInfo()
        try await waitUntil { session.diagnostics.serverVersion != nil && loaded != nil }

        #expect(session.diagnostics.serverVersion == "4.7.3")
        #expect(loaded?.autoplaysAnimations == true)
        // 次の起動では、読み直す前から、覚えた値で描く。
        let next = AppSettings(defaults: defaults)
        next.followServerPreferences(of: session.credential.handle)
        #expect(next.animatesAvatars == settings.animatesAvatars)
    }

    /// ストリーミングの状態は、UIが渡さなくても接続の状態に入り、そのあとでUIに知らせる。
    @Test func streamingStateReachesDiagnosticsBeforeUI() async throws {
        let session = AccountSession.testing(transport: transport(), connector: ScriptedConnector([.init()]))
        defer { session.close() }
        var statesWhenNotified: [ConnectionDiagnostics.StreamingState?] = []
        session.onStreamingChange = { statesWhenNotified.append(session.diagnostics.streaming) }

        let subscription = session.streamingHub.subscribe(StreamingSubscription(stream: "user")) { _ in }
        defer { subscription.cancel() }
        try await waitUntil { session.diagnostics.streaming == .connected }

        #expect(statesWhenNotified.last == .connected)
        #expect(session.diagnostics.streamingSubscriptions.map(\.stream) == ["user"])
    }

    /// 処理できなかった画像の形式は、読めたサーバーの版で覚え、同じ版の間は送らない形式として返す。
    @Test func composeMediaServiceRemembersUnprocessableFormatForServerVersion() async throws {
        let session = AccountSession.testing(transport: transport())
        defer { session.close() }
        session.start { 0 }
        session.loadServerInfo()
        try await waitUntil { session.diagnostics.serverVersion != nil }
        let media: ComposeMediaService = session.composeMediaService { _ in nil }

        media.recordUnprocessableImageType("image/heic")

        #expect(media.unprocessableImageTypes() == ["image/heic"])
        #expect(session.mediaFormats.mimeTypes(serverVersion: "4.7.3") == ["image/heic"])
        #expect(session.mediaFormats.mimeTypes(serverVersion: "4.8.0").isEmpty)
    }

    /// 送る前に縮める大きさは、口を作ったあとに設定を変えても、その時点の設定で読む。
    @Test func composeMediaServiceReadsCurrentUploadSize() throws {
        let defaults = TestScratch.defaults("AccountSessionStoresTests.preparation")
        let settings = AppSettings(defaults: defaults)
        let session = AccountSession.testing(transport: transport(), settings: settings, defaults: defaults)
        defer { session.close() }
        let media: ComposeMediaService = session.composeMediaService { _ in nil }
        let other = try #require(ImageUploadSize.allCases.first { $0 != settings.imageUploadSize })

        settings.imageUploadSize = other

        #expect(media.preparation().imageSize == other)
    }

    /// 訳す部品を渡さないUIでは、自動翻訳のストアを作らない。
    @Test func noTranslationStoreWithoutTranslator() {
        let session = AccountSession.testing(transport: transport())
        defer { session.close() }

        #expect(session.translations == nil)
    }

    /// 自動翻訳の設定を変えたら、セッションがストアへ入れ直してからUIに知らせる。入れ直す前の言語の投稿は訳さず、入れ直したあとは訳す。
    @Test func translationSettingsReachStoreBeforeUI() async throws {
        let defaults = TestScratch.defaults("AccountSessionStoresTests.translation")
        let settings = AppSettings(defaults: defaults)
        settings.isAutoTranslationEnabled = true
        settings.autoTranslationLanguages = []
        let translator = EchoTranslator()
        let session = AccountSession.testing(
            transport: transport(),
            settings: settings,
            defaults: defaults,
            translation: StatusTranslationSetup(translator: translator, targetLanguage: { "ja" }, strategy: { .lowLatency })
        )
        defer { session.close() }
        let translations = try #require(session.translations)
        let source = TranslationSource(status(language: "en"))
        translations.request([source])
        #expect(!translations.isTranslating(source))
        var notified = 0
        session.onTranslationSettingsChange = { notified += 1 }

        settings.autoTranslationLanguages = ["en"]
        try await waitUntil { notified == 1 }
        translations.request([source])

        try await waitUntil { translator.targets.withLock { $0 } == ["ja"] }
    }

    /// 「リストに追加」の口は、相手との関係が返らなければ、見つからなかった人のハンドルを理由にする。
    @Test func listMembershipAPIReportsMissingRelationship() async throws {
        let session = AccountSession.testing(transport: RoutedTransport { request in
            request.url?.path() == "/api/v1/accounts/relationships" ? (200, Data("[]".utf8)) : (404, Data())
        })
        defer { session.close() }
        let api = session.listMembershipAPI(accountID: "9", acct: "carol@remote.example")

        let error = await #expect(throws: ProfileNotFound.self) {
            try await RequestPurpose.$current.withValue(.action) { try await api.relationship() }
        }

        #expect(error == ProfileNotFound(acct: "carol@remote.example"))
    }

    /// 閉じたら、セッションが持つキャッシュが始めた通信も止める。
    @Test func closingStopsAccountAndRelationshipLoads() async throws {
        let gate = Gate()
        let session = AccountSession.testing(transport: RoutedTransport { _ in
            try await gate.wait()
            return (200, Data("[]".utf8))
        })
        session.relationships.reload(["9"], purpose: .action)
        try await waitUntil { gate.waiterCount == 1 }

        session.close()

        try await waitUntil { gate.waiterCount == 0 }
    }
}
