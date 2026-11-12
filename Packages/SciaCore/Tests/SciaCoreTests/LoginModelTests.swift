import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// ログインの途中でサーバーの応答が長引いたら、やめる操作を出す。
@MainActor
struct LoginModelTests {
    private struct Setup {
        let model: LoginModel
        let clock: TestClock
        /// アプリの登録の応答を止める門。
        let registration: Gate
    }

    private func makeModel() throws -> Setup {
        let registration = Gate()
        let transport = RoutedTransport { request in
            try await registration.wait()
            return switch request.url?.path() {
            case "/api/v1/apps": (200, try Self.fixture("credential_application"))
            default: (500, Data(#"{"error":"Internal Server Error"}"#.utf8))
            }
        }
        let oauth = OAuthClient(
            configuration: OAuthClient.Configuration(redirectURI: try #require(URL(string: "net.mizle.scia://oauth"))),
            client: HTTPClient(transport: transport)
        )
        let clock = TestClock()
        let model = LoginModel(oauth: oauth, clock: clock) { _ in }
        model.instanceInput = "example.social"
        return Setup(model: model, clock: clock, registration: registration)
    }

    nonisolated private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    /// 応答を待つのが、待つのをやめる長さより長引くまでは、やめる操作を出さない。
    @Test func offersCancelOnlyAfterLimit() async throws {
        let setup = try makeModel()
        setup.model.startLogin { _ in throw CancellationError() }
        try await waitUntil { setup.registration.waiterCount >= 1 && setup.clock.sleeperCount(remaining: ResponseWait.limit) >= 1 }
        #expect(setup.model.isLoggingIn)

        setup.clock.advance(by: ResponseWait.limit - .milliseconds(1))
        #expect(!setup.model.offersCancel)

        setup.clock.advance(by: .milliseconds(1))
        try await waitUntil { setup.model.offersCancel }

        setup.registration.open()
        try await waitUntil { !setup.model.isLoggingIn }
        #expect(!setup.model.offersCancel)
    }

    /// やめたら、失敗として出さずに、打ち直せる状態に戻す。
    @Test func cancelStopsLoginWithoutError() async throws {
        let setup = try makeModel()
        setup.model.startLogin { _ in throw CancellationError() }
        try await waitUntil { setup.registration.waiterCount >= 1 && setup.clock.sleeperCount(remaining: ResponseWait.limit) >= 1 }
        try await setup.clock.advance(afterSleeping: ResponseWait.limit)
        try await waitUntil { setup.model.offersCancel }

        setup.model.cancelLogin()

        try await waitUntil { !setup.model.isLoggingIn }
        #expect(!setup.model.offersCancel)
        #expect(setup.model.errorMessage == nil)
        #expect(setup.clock.sleeperCount(dueWithin: ResponseWait.limit) == 0)
    }

    /// 認可画面を出している間は、待っているのが使う人の操作なので、やめる操作を出さない。戻ってからの応答が長引いたら出す。
    @Test func doesNotOfferCancelWhileAuthenticating() async throws {
        let setup = try makeModel()
        let authentication = Gate()
        setup.registration.open()
        setup.model.startLogin { url in
            try await authentication.wait()
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return try #require(URL(string: "net.mizle.scia://oauth?code=auth-code&state=\(state)"))
        }
        try await waitUntil { authentication.waiterCount >= 1 && setup.clock.sleeperCount(dueWithin: ResponseWait.limit) == 0 }
        #expect(!setup.model.offersCancel)

        authentication.open()
        // トークンの取得は500で失敗し、ログインが終わる。終わる前に、待ち直しが始まったことを確かめられないので、終わったあとの状態だけを見る。
        try await waitUntil { !setup.model.isLoggingIn }
        #expect(!setup.model.offersCancel)
        #expect(setup.model.errorMessage != nil)
    }
}
