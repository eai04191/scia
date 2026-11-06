import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct AuthorizationCheckTests {
    /// MastodonのREST APIは、トークンが無効なときだけ401を返すので、確かめずに無効とする。
    @Test func restUnauthorizedIsInvalidWithoutVerification() {
        let verifier = ScriptedVerifier([])
        let check = AuthorizationCheck(verify: verifier.verify)
        var changes: [AuthorizationCheck.State] = []
        check.onChange = { changes.append($0) }

        check.reportUnauthorized()
        check.reportUnauthorized()

        #expect(check.state == .invalid)
        #expect(changes == [.invalid])
        #expect(verifier.callCount == 0)
    }

    /// ストリーミングの401を確かめている途中にREST APIの401を受けたら、確かめた結果が有効でも無効のままにする。
    @Test func restUnauthorizedDuringStreamingVerificationStaysInvalid() async throws {
        let gate = Gate()
        let verifier = ScriptedVerifier([.success(())], gate: gate)
        let check = AuthorizationCheck(verify: verifier.verify)
        var changes: [AuthorizationCheck.State] = []
        check.onChange = { changes.append($0) }

        let streaming = Task { await check.reportStreamingUnauthorized() }
        try await waitUntil { gate.waiterCount == 1 }
        check.reportUnauthorized()
        gate.open()

        #expect(await streaming.value == .invalid)
        #expect(check.state == .invalid)
        #expect(changes == [.invalid])
    }

    /// REST APIの401で無効になったあとは、ストリーミングの401でも確かめ直さない。
    @Test func streamingUnauthorizedAfterRestIsNotVerified() async {
        let verifier = ScriptedVerifier([])
        let check = AuthorizationCheck(verify: verifier.verify)

        check.reportUnauthorized()

        #expect(await check.reportStreamingUnauthorized() == .invalid)
        #expect(verifier.callCount == 0)
    }

    @Test func invalidWhenVerificationIsAlsoUnauthorized() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: "The access token is invalid"))])
        let check = AuthorizationCheck(verify: verifier.verify)

        #expect(await check.reportStreamingUnauthorized() == .invalid)
        #expect(check.state == .invalid)
    }

    /// ストリーミングは、消したリストや許可の範囲が足りないときにも、有効なトークンで401を返す。そのときにログインし直しを求めない。
    @Test func staysValidWhenVerificationSucceeds() async {
        let verifier = ScriptedVerifier([.success(())])
        let check = AuthorizationCheck(verify: verifier.verify)

        #expect(await check.reportStreamingUnauthorized() == .valid)
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

        #expect(await check.reportStreamingUnauthorized() == .valid)
    }

    @Test func concurrentReportsShareOneVerification() async throws {
        let gate = Gate()
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))], gate: gate)
        let check = AuthorizationCheck(verify: verifier.verify)

        let first = Task { await check.reportStreamingUnauthorized() }
        try await waitUntil { gate.waiterCount == 1 }
        // 2つ目の報告は、確かめている途中で待ち始めるまで同じアクターの上で進むので、門はそれより後に開く。
        Task { gate.open() }
        let second = await check.reportStreamingUnauthorized()

        #expect(await first.value == .invalid)
        #expect(second == .invalid)
        #expect(verifier.callCount == 1)
    }

    @Test func invalidStateIsNotVerifiedAgain() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(verify: verifier.verify)

        _ = await check.reportStreamingUnauthorized()
        #expect(await check.reportStreamingUnauthorized() == .invalid)
        #expect(verifier.callCount == 1)
    }

    /// 同じAPIが401を返し続けても、確かめる通信を繰り返さない。
    @Test func recentSuccessfulVerificationIsReused() async {
        let verifier = ScriptedVerifier([.success(())])
        let check = AuthorizationCheck(revalidationInterval: .seconds(3600), verify: verifier.verify)

        _ = await check.reportStreamingUnauthorized()
        #expect(await check.reportStreamingUnauthorized() == .valid)
        #expect(verifier.callCount == 1)
    }

    /// 確かめられなかっただけでは有効と分かったことにならないため、次の401ですぐ確かめ直す。
    @Test func failedVerificationIsNotReused() async {
        let verifier = ScriptedVerifier([.failure(URLError(.timedOut)), .failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(revalidationInterval: .seconds(3600), verify: verifier.verify)

        #expect(await check.reportStreamingUnauthorized() == .valid)
        #expect(await check.reportStreamingUnauthorized() == .invalid)
        #expect(verifier.callCount == 2)
    }

    @Test func verifiesAgainAfterInterval() async {
        let verifier = ScriptedVerifier([.success(()), .failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(revalidationInterval: .zero, verify: verifier.verify)

        #expect(await check.reportStreamingUnauthorized() == .valid)
        #expect(await check.reportStreamingUnauthorized() == .invalid)
        #expect(verifier.callCount == 2)
    }

    @Test func notifiesWhenBecomingInvalid() async {
        let verifier = ScriptedVerifier([.failure(MastodonAPIError(statusCode: 401, message: ""))])
        let check = AuthorizationCheck(verify: verifier.verify)
        var changes: [AuthorizationCheck.State] = []
        check.onChange = { changes.append($0) }

        _ = await check.reportStreamingUnauthorized()
        _ = await check.reportStreamingUnauthorized()

        #expect(changes == [.invalid])
    }
}

/// 呼ばれた順に、決めておいた結果を返す確認の処理。
private final class ScriptedVerifier: Sendable {
    private let results: Mutex<[Result<Void, any Error>]>
    private let calls = Mutex(0)
    /// 開くまで、確かめ終えない。
    private let gate: Gate?

    init(_ results: [Result<Void, any Error>], gate: Gate? = nil) {
        self.results = Mutex(results)
        self.gate = gate
    }

    var callCount: Int { calls.withLock { $0 } }

    var verify: @Sendable () async throws -> Void {
        { [self] in
            calls.withLock { $0 += 1 }
            try await gate?.wait()
            let result = results.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let result else {
                Issue.record("想定より多く確かめました")
                return
            }
            try result.get()
        }
    }
}
