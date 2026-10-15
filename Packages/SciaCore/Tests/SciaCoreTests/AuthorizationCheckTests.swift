import Foundation
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct AuthorizationCheckTests {
    @Test func invalidWhenVerificationIsAlsoUnauthorized() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: "The access token is invalid"))])
        let check = AuthorizationCheck(verify: verifier.verify)

        #expect(await check.reportUnauthorized() == .invalid)
        #expect(check.state == .invalid)
    }

    /// 一部のAPIだけが401を返すサーバーで、ログインし直しを求めないようにする。
    @Test func staysValidWhenVerificationSucceeds() async {
        let verifier = ScriptedVerifier([.success(())])
        let check = AuthorizationCheck(verify: verifier.verify)

        #expect(await check.reportUnauthorized() == .valid)
        #expect(check.state == .valid)
    }

    /// 確かめる通信が一時的に失敗しても、トークンが無効とは決めつけない。
    @Test(arguments: [
        MastodonAPIError(statusCode: 503, message: "Service Unavailable") as any Error,
        URLError(.notConnectedToInternet),
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "壊れた応答")),
    ])
    func staysValidWhenVerificationFailsOtherwise(error: any Error) async {
        let verifier = ScriptedVerifier([.failure(error)])
        let check = AuthorizationCheck(verify: verifier.verify)

        #expect(await check.reportUnauthorized() == .valid)
    }

    @Test func concurrentReportsShareOneVerification() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))], delay: .milliseconds(20))
        let check = AuthorizationCheck(verify: verifier.verify)

        async let first = check.reportUnauthorized()
        async let second = check.reportUnauthorized()

        #expect(await [first, second] == [.invalid, .invalid])
        #expect(verifier.callCount == 1)
    }

    @Test func invalidStateIsNotVerifiedAgain() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(verify: verifier.verify)

        _ = await check.reportUnauthorized()
        #expect(await check.reportUnauthorized() == .invalid)
        #expect(verifier.callCount == 1)
    }

    /// 同じAPIが401を返し続けても、確かめる通信を繰り返さない。
    @Test func recentSuccessfulVerificationIsReused() async {
        let verifier = ScriptedVerifier([.success(())])
        let check = AuthorizationCheck(revalidationInterval: .seconds(3600), verify: verifier.verify)

        _ = await check.reportUnauthorized()
        #expect(await check.reportUnauthorized() == .valid)
        #expect(verifier.callCount == 1)
    }

    /// 確かめられなかっただけでは有効と分かったことにならないため、次の401ですぐ確かめ直す。
    @Test func failedVerificationIsNotReused() async {
        let verifier = ScriptedVerifier([.failure(URLError(.timedOut)), .failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(revalidationInterval: .seconds(3600), verify: verifier.verify)

        #expect(await check.reportUnauthorized() == .valid)
        #expect(await check.reportUnauthorized() == .invalid)
        #expect(verifier.callCount == 2)
    }

    @Test func verifiesAgainAfterInterval() async {
        let verifier = ScriptedVerifier([.success(()), .failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(revalidationInterval: .zero, verify: verifier.verify)

        #expect(await check.reportUnauthorized() == .valid)
        #expect(await check.reportUnauthorized() == .invalid)
        #expect(verifier.callCount == 2)
    }

    @Test func notifiesWhenBecomingInvalid() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(verify: verifier.verify)
        var changes: [AuthorizationCheck.State] = []
        check.onChange = { changes.append($0) }

        _ = await check.reportUnauthorized()
        _ = await check.reportUnauthorized()

        #expect(changes == [.invalid])
    }
}

/// 呼ばれた順に、決めておいた結果を返す確認の処理。
private final class ScriptedVerifier: Sendable {
    private let results: Mutex<[Result<Void, any Error>]>
    private let calls = Mutex(0)
    private let delay: Duration

    init(_ results: [Result<Void, any Error>], delay: Duration = .zero) {
        self.results = Mutex(results)
        self.delay = delay
    }

    var callCount: Int { calls.withLock { $0 } }

    var verify: @Sendable () async throws -> Void {
        { [self] in
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: delay)
            let result = results.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let result else {
                Issue.record("想定より多く確かめました")
                return
            }
            try result.get()
        }
    }
}
