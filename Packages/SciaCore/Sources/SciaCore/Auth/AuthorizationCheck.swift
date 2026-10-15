/// APIが401を返したときに、トークンが本当に無効かを確かめる。
///
/// 一部のAPIだけを401で断るサーバーや、手前のプロキシが一時的に401を返すことがあるため、1つの401ではトークンが無効と決めない。
/// `verify_credentials`も401を返したときだけ無効とする。無効になっても資格情報は消さない。消すのは、使う人がログアウトを選んだときだけ。
@MainActor
public final class AuthorizationCheck {
    public enum State: Sendable, Equatable {
        case valid
        /// ログインし直すまで、どのAPIも成功しない。
        case invalid
    }

    public private(set) var state = State.valid
    /// 状態が変わったときに呼ぶ。
    public var onChange: ((State) -> Void)?

    private let verify: @Sendable () async throws -> Void
    /// 確かめて有効だった後、この間は確かめ直さない。同じAPIが401を返し続けても、確かめる通信を繰り返さないため。
    private let revalidationInterval: Duration
    private var lastValidated: ContinuousClock.Instant?
    private var verifying: Task<Outcome, Never>?

    /// 確かめた結果。確かめられなかったときは有効として扱うが、有効と分かったわけではないので、次の401ですぐ確かめ直す。
    private enum Outcome {
        case verified
        case unverified
        case invalid

        var state: State { self == .invalid ? .invalid : .valid }
    }

    /// - Parameter verify: トークンが有効なら返り、無効なら401の`MastodonAPIError`を投げる。
    public init(revalidationInterval: Duration = .seconds(60), verify: @escaping @Sendable () async throws -> Void) {
        self.revalidationInterval = revalidationInterval
        self.verify = verify
    }

    /// 401を受けたときに呼び、確かめた後の状態を返す。確かめている途中に呼ばれたら、その結果を待つ。
    @discardableResult
    public func reportUnauthorized() async -> State {
        if state == .invalid { return .invalid }
        if let lastValidated, ContinuousClock.now - lastValidated < revalidationInterval { return .valid }
        if let verifying { return await verifying.value.state }
        let verify = verify
        let task = Task { () -> Outcome in
            do {
                try await verify()
                return .verified
            } catch let error as MastodonAPIError where error.isUnauthorized {
                return .invalid
            } catch {
                // 確かめる通信そのものが失敗しただけでは、無効とは言えない。
                return .unverified
            }
        }
        verifying = task
        let outcome = await task.value
        verifying = nil
        if outcome == .verified {
            lastValidated = .now
        }
        if outcome.state != state {
            state = outcome.state
            onChange?(state)
        }
        return outcome.state
    }
}
