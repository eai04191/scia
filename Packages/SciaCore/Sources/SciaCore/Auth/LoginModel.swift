public import Foundation
public import Observation
import os

@MainActor
@Observable
public final class LoginModel {
    public var instanceInput = ""
    public private(set) var isLoggingIn = false
    /// サーバーの応答を待つのが`ResponseWait.limit`より長引いている。ログインをやめる操作を出す。
    /// 認可画面を出している間は、待っているのが使う人の操作なので数えない。
    public private(set) var offersCancel = false
    public private(set) var errorMessage: String?

    /// ログインできたときに呼ぶ。保存に失敗したら投げ、ログイン画面にエラーを出す。
    private let onLogin: @MainActor (Credential) throws -> Void
    private let serverSuggestions: ServerSuggestions
    private let oauth: OAuthClient
    private let clock: any Clock<Duration>
    private var loginTask: Task<Void, Never>?
    private var cancelOffer: Task<Void, Never>?
    private let logger = SciaLog.logger(category: "login")

    /// - Parameters:
    ///   - oauth: アプリを登録し、認可の結果をアクセストークンに替える。
    ///   - accountDomains: ログイン済みのアカウントのサーバー。候補の上に出す。
    public init(
        oauth: OAuthClient,
        accountDomains: [String] = [],
        clock: any Clock<Duration> = SystemTime.clock,
        onLogin: @escaping @MainActor (Credential) throws -> Void
    ) {
        self.oauth = oauth
        self.clock = clock
        self.onLogin = onLogin
        let knownDomains: [String]
        do {
            knownDomains = try ServerSuggestions.loadKnownDomains()
        } catch {
            // サーバーのリストはアプリに同梱していて、読めないのはビルドの誤りに限る。ログインは打てばできるので、候補をログイン済みのサーバーだけにして続ける。
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

    /// ログインを始める。やめられるよう、処理を覚えておく。
    /// - Parameter authenticate: 認可画面のURLを開き、使う人が許可したあとのコールバックのURLを返す。やめたら`CancellationError`を投げる。
    public func startLogin(authenticate: @escaping @Sendable (URL) async throws -> URL) {
        guard !isLoggingIn else { return }
        loginTask = Task(.action) { [weak self] in
            await self?.login(authenticate: authenticate)
        }
    }

    /// 走っているログインをやめる。サーバーのアドレスを打ち直せるようにする。
    public func cancelLogin() {
        loginTask?.cancel()
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
        offerCancelAfterLimit()
        defer {
            stopOfferingCancel()
            isLoggingIn = false
        }
        do {
            let credential = try await oauth.login(instance: instance) { [weak self] url in
                await self?.stopOfferingCancel()
                let callback = try await authenticate(url)
                await self?.offerCancelAfterLimit()
                return callback
            }
            logger.info("login succeeded instance=\(SciaLog.host(of: instance), privacy: .public)")
            try onLogin(credential)
        } catch where error is CancellationError || Task.isCancelled {
            // やめたときの通信の取り消しは、失敗として出さない。
            logger.info("login cancelled")
        } catch {
            logger.error("login failed: \(SciaLog.describe(error), privacy: .public)")
            errorMessage = ErrorPresentation(error).text
        }
    }

    private func offerCancelAfterLimit() {
        stopOfferingCancel()
        cancelOffer = Task(.withoutRequests) { [weak self, clock] in
            guard (try? await clock.sleep(for: ResponseWait.limit)) != nil else { return }
            self?.offersCancel = true
        }
    }

    private func stopOfferingCancel() {
        cancelOffer?.cancel()
        cancelOffer = nil
        offersCancel = false
    }
}
