import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct OAuthClientTests {
    private func makeInstance() throws -> URL {
        try #require(URL(string: "https://example.social"))
    }

    private func makeConfiguration() throws -> OAuthClient.Configuration {
        OAuthClient.Configuration(
            clientName: "Scia",
            redirectURI: try #require(URL(string: "net.mizle.scia://oauth")),
            scopes: "read write"
        )
    }

    private func queryItems(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }

    private func formItems(_ body: Data?) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = body.map { String(decoding: $0, as: UTF8.self) }
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }

    @Test func pkceMatchesRFC7636Example() {
        // RFC 7636 Appendix Bの例
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func loginRunsWholeFlowAndReturnsCredential() async throws {
        let instance = try makeInstance()
        let transport = StubTransport([
            try .fixture("credential_application"),
            try .fixture("token"),
            try .fixture("verify_credentials"),
        ])
        let client = OAuthClient(configuration: try makeConfiguration(), transport: transport)

        let credential = try await client.login(instance: instance) { authorizeURL in
            let query = queryItems(authorizeURL)
            #expect(authorizeURL.host() == "example.social")
            #expect(authorizeURL.path() == "/oauth/authorize")
            #expect(query["response_type"] == "code")
            #expect(query["client_id"] == "TWhM-tNSuncnqN7DBJmoyeLnk6K3iJJ71KKXxgL1hPM")
            #expect(query["redirect_uri"] == "net.mizle.scia://oauth")
            #expect(query["scope"] == "read write")
            #expect(query["code_challenge_method"] == "S256")
            let state = try #require(query["state"])
            return try #require(URL(string: "net.mizle.scia://oauth?code=auth-code&state=\(state)"))
        }

        #expect(credential == Credential(
            instance: instance,
            accessToken: "ZA-Yj3aBD8U8Cm7lKUp-lm9O9BmDgdhHzDeqsY8tlL0",
            clientID: "TWhM-tNSuncnqN7DBJmoyeLnk6K3iJJ71KKXxgL1hPM",
            clientSecret: "ZEaFUFmF0umgBX1qKJDjaU99Q31lDkOU8NutzTOoliw",
            accountID: "14715",
            username: "alice"
        ))

        let requests = await transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /api/v1/apps",
            "POST /oauth/token",
            "GET /api/v1/accounts/verify_credentials",
        ])

        let appBody = try #require(requests[0].httpBody)
        let app = try #require(try JSONSerialization.jsonObject(with: appBody) as? [String: Any])
        #expect(app["client_name"] as? String == "Scia")
        // 4.3より前のMastodonは配列を受け取らず、リダイレクトURIが空として422を返す。
        #expect(app["redirect_uris"] as? String == "net.mizle.scia://oauth")
        #expect(app["scopes"] as? String == "read write")

        let token = formItems(requests[1].httpBody)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(token["grant_type"] == "authorization_code")
        #expect(token["code"] == "auth-code")
        #expect(token["client_secret"] == "ZEaFUFmF0umgBX1qKJDjaU99Q31lDkOU8NutzTOoliw")
        #expect(token["redirect_uri"] == "net.mizle.scia://oauth")
        #expect(token["code_verifier"]?.isEmpty == false)

        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer ZA-Yj3aBD8U8Cm7lKUp-lm9O9BmDgdhHzDeqsY8tlL0")
    }

    @Test func codeVerifierMatchesChallengeSentToAuthorize() async throws {
        let transport = StubTransport([
            try .fixture("credential_application"),
            try .fixture("token"),
            try .fixture("verify_credentials"),
        ])
        let client = OAuthClient(configuration: try makeConfiguration(), transport: transport)
        let challenge = Locked<String?>(nil)

        _ = try await client.login(instance: try makeInstance()) { authorizeURL in
            let query = queryItems(authorizeURL)
            challenge.set(query["code_challenge"])
            let state = try #require(query["state"])
            return try #require(URL(string: "net.mizle.scia://oauth?code=auth-code&state=\(state)"))
        }

        let verifier = try #require(formItems(await transport.requests[1].httpBody)["code_verifier"])
        #expect(PKCE(verifier: verifier).challenge == challenge.get())
    }

    @Test func rejectsCallbackWithDifferentState() throws {
        let client = OAuthClient(configuration: try makeConfiguration(), transport: StubTransport([]))
        let callback = try #require(URL(string: "net.mizle.scia://oauth?code=auth-code&state=other"))

        #expect(throws: OAuthClient.LoginError.stateMismatch) {
            try client.authorizationCode(from: callback, expectedState: "expected")
        }
    }

    @Test func reportsDeniedAuthorization() throws {
        let client = OAuthClient(configuration: try makeConfiguration(), transport: StubTransport([]))
        let callback = try #require(URL(string: "net.mizle.scia://oauth?error=access_denied&error_description=denied&state=expected"))

        #expect(throws: OAuthClient.LoginError.authorizationDenied("access_denied: denied")) {
            try client.authorizationCode(from: callback, expectedState: "expected")
        }
    }

    @Test func rejectsCallbackWithoutCode() throws {
        let client = OAuthClient(configuration: try makeConfiguration(), transport: StubTransport([]))
        let callback = try #require(URL(string: "net.mizle.scia://oauth?state=expected"))

        #expect(throws: OAuthClient.LoginError.missingCode) {
            try client.authorizationCode(from: callback, expectedState: "expected")
        }
    }

    @Test func surfacesServerErrorMessage() async throws {
        let transport = StubTransport([
            .json(#"{"error":"Validation failed: Redirect URI must be an absolute URI."}"#, statusCode: 422),
        ])
        let client = OAuthClient(configuration: try makeConfiguration(), transport: transport)

        let reason = "Validation failed: Redirect URI must be an absolute URI."
        await #expect(throws: MastodonAPIError(statusCode: 422, message: reason, serverMessage: reason)) {
            _ = try await client.login(instance: try makeInstance()) { _ in
                Issue.record("アプリ登録に失敗したら認可画面を開かない")
                throw CancellationError()
            }
        }
    }

    @Test func formEncodesPlusSign() async throws {
        let transport = StubTransport([try .fixture("token")])
        let client = OAuthClient(configuration: try makeConfiguration(), transport: transport)
        let app = OAuthClient.RegisteredApp(clientId: "id", clientSecret: "a+b/c=")

        _ = try await client.exchangeToken(instance: try makeInstance(), app: app, code: "code", pkce: PKCE(verifier: "v"))

        #expect(formItems(await transport.requests[0].httpBody)["client_secret"] == "a+b/c=")
    }
}

/// テストのクロージャから値を持ち出すための入れ物。
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }

    func get() -> Value {
        mutex.withLock { $0 }
    }
}
