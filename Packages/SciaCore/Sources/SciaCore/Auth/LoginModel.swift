public import Foundation
public import Observation
import os

@MainActor
@Observable
public final class LoginModel {
    public var instanceInput = ""
    public private(set) var isLoggingIn = false
    public private(set) var errorMessage: String?

    /// ログインできたときに呼ぶ。保存に失敗したら投げ、ログイン画面にエラーを出す。
    private let onLogin: @MainActor (Credential) throws -> Void
    private let serverSuggestions: ServerSuggestions
    private let oauth: OAuthClient
    private let logger = SciaLog.logger(category: "login")

    /// - Parameters:
    ///   - oauth: アプリを登録し、認可の結果をアクセストークンに替える。
    ///   - accountDomains: ログイン済みのアカウントのサーバー。候補の上に出す。
    public init(oauth: OAuthClient, accountDomains: [String] = [], onLogin: @escaping @MainActor (Credential) throws -> Void) {
        self.oauth = oauth
        self.onLogin = onLogin
        let knownDomains: [String]
        do {
            knownDomains = try ServerSuggestions.loadKnownDomains()
        } catch {
            // 一覧はアプリに同梱していて、読めないのはビルドの誤りに限る。ログインは打てばできるので、候補をログイン済みのサーバーだけにして続ける。
            logger.error("known servers unavailable: \(SciaLog.describe(error), privacy: .public)")
            knownDomains = []
        }
        serverSuggestions = ServerSuggestions(accountDomains: accountDomains, knownDomains: knownDomains)
    }

    /// 打ったアドレスに合うサーバー。
    public var suggestions: [String] {
        serverSuggestions.suggestions(for: instanceInput)
    }

    public func showError(_ message: String) {
        errorMessage = message
    }

    /// - Parameter authenticate: 認可画面のURLを開き、使う人が許可したあとのコールバックのURLを返す。やめたら`CancellationError`を投げる。
    public func login(authenticate: @escaping @Sendable (URL) async throws -> URL) async {
        errorMessage = nil
        let instance: URL
        do {
            instance = try InstanceAddress.parse(instanceInput)
        } catch {
            errorMessage = ErrorPresentation(error).text
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let credential = try await oauth.login(instance: instance, authenticate: authenticate)
            logger.info("login succeeded instance=\(SciaLog.host(of: instance), privacy: .public)")
            try onLogin(credential)
        } catch is CancellationError {
            logger.info("login cancelled")
        } catch {
            logger.error("login failed: \(SciaLog.describe(error), privacy: .public)")
            errorMessage = ErrorPresentation(error).text
        }
    }
}
