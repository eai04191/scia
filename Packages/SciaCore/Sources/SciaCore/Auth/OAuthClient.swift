public import Foundation

/// Mastodonのアプリ登録からアクセストークンの取得、アカウントの確認までを行う。
public struct OAuthClient: Sendable {
    public struct Configuration: Sendable {
        public let clientName: String
        public let redirectURI: URL
        public let scopes: String

        public init(clientName: String, redirectURI: URL, scopes: String) {
            self.clientName = clientName
            self.redirectURI = redirectURI
            self.scopes = scopes
        }
    }

    public enum LoginError: Error, Equatable, LocalizedError {
        /// 認可画面でユーザーが拒否した、またはサーバーが認可を返さなかった。
        case authorizationDenied(String)
        /// コールバックのstateが送ったものと一致しない。
        case stateMismatch
        /// コールバックに認可コードがない。
        case missingCode

        public var errorDescription: String? {
            switch self {
            case .authorizationDenied(let reason): "認可されませんでした: \(reason)"
            case .stateMismatch: "認可の応答が、このアプリから送った要求と一致しませんでした"
            case .missingCode: "認可の応答に認可コードがありませんでした"
            }
        }
    }

    /// 登録したアプリの情報。
    public struct RegisteredApp: Decodable, Sendable, Equatable {
        public let clientId: String
        public let clientSecret: String
    }

    /// 認可画面を開くためのURLと、応答の検証に使う値。
    public struct AuthorizationRequest: Sendable, Equatable {
        public let url: URL
        public let state: String
        public let pkce: PKCE
    }

    public let configuration: Configuration
    /// 通信の入口。ログインは使う人の操作なので、自動の通信が止められている間も送る。
    private let client: HTTPClient

    public init(configuration: Configuration, client: HTTPClient) {
        self.configuration = configuration
        self.client = client
    }

    /// ログインの全体。`authenticate`は認可画面のURLを開き、リダイレクト先のURLを返す。
    public func login(
        instance: URL,
        authenticate: @Sendable (URL) async throws -> URL
    ) async throws -> Credential {
        let app = try await registerApp(instance: instance)
        let request = makeAuthorizationRequest(instance: instance, app: app, state: PKCE.randomURLSafeString(byteCount: 16), pkce: .random())
        let callback = try await authenticate(request.url)
        let code = try authorizationCode(from: callback, expectedState: request.state)
        let token = try await exchangeToken(instance: instance, app: app, code: code, pkce: request.pkce)
        let account = try await verifyCredentials(instance: instance, accessToken: token)
        return Credential(
            instance: instance,
            accessToken: token,
            clientID: app.clientId,
            clientSecret: app.clientSecret,
            accountID: account.id,
            username: account.username
        )
    }

    /// https://docs.joinmastodon.org/methods/apps/#create
    func registerApp(instance: URL) async throws -> RegisteredApp {
        struct Body: Encodable {
            let client_name: String
            /// 配列でも送れるのは4.3からで、それより前のサーバーは配列を捨てて422を返すため、1つの文字列で送る。
            let redirect_uris: String
            let scopes: String
        }
        var request = URLRequest(url: instance.appending(path: "api/v1/apps"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            client_name: configuration.clientName,
            redirect_uris: configuration.redirectURI.absoluteString,
            scopes: configuration.scopes
        ))
        return try await decode(RegisteredApp.self, from: request)
    }

    /// https://docs.joinmastodon.org/methods/oauth/#authorize
    func makeAuthorizationRequest(instance: URL, app: RegisteredApp, state: String, pkce: PKCE) -> AuthorizationRequest {
        var components = URLComponents()
        components.scheme = instance.scheme
        components.host = instance.host()
        components.port = instance.port
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: app.clientId),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            preconditionFailure("インスタンスのURLから認可画面のURLを組み立てられません: \(instance)")
        }
        return AuthorizationRequest(url: url, state: state, pkce: pkce)
    }

    func authorizationCode(from callback: URL, expectedState: String) throws(LoginError) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw .authorizationDenied([error, value("error_description")].compactMap(\.self).joined(separator: ": "))
        }
        guard value("state") == expectedState else { throw .stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    /// https://docs.joinmastodon.org/methods/oauth/#token
    func exchangeToken(instance: URL, app: RegisteredApp, code: String, pkce: PKCE) async throws -> String {
        struct Token: Decodable {
            let accessToken: String
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: app.clientId),
            URLQueryItem(name: "client_secret", value: app.clientSecret),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "code_verifier", value: pkce.verifier),
        ]
        var request = URLRequest(url: instance.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(form).utf8)
        return try await decode(Token.self, from: request).accessToken
    }

    /// https://docs.joinmastodon.org/methods/accounts/#verify_credentials
    func verifyCredentials(instance: URL, accessToken: String) async throws -> Account {
        var request = URLRequest(url: instance.appending(path: "api/v1/accounts/verify_credentials"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await decode(Account.self, from: request)
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await client.response(for: request, limit: ResponseLimit.api, scope: .host)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonAPIError.from(statusCode: response.statusCode, body: data)
        }
        return try MastodonDecoder.make().decode(type, from: data)
    }

    /// URLComponentsは`+`をエンコードしないが、form-urlencodedでは`+`が空白として読まれるため、エンコードしておく。
    private static func formEncoded(_ components: URLComponents) -> String {
        (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
