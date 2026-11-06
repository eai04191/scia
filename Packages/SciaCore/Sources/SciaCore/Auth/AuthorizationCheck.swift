/// 401を受けたときに、トークンが無効になったか（ログアウトされたか）を決める。
///
/// MastodonのREST APIは、トークンが無効なときだけ401を返す。有効なトークンで断るとき（アカウントの停止、許可の範囲が足りないなど）は403。
/// そのため、REST APIの401では確かめずに無効とする。
/// ストリーミングは、有効なトークンでも、消したリストや許可の範囲が足りないときに401を返す（Mastodonの`streaming/index.js`の`AuthenticationError`）。
/// そのため、ストリーミングの401では、REST APIの`verify_credentials`も401を返したときだけ無効とする。
/// 無効になっても資格情報は消さない。消すのは、使う人がログアウトを選んだときだけ。
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
    /// 確かめて有効だった時点から経った長さ。まだ有効と確かめていなければnil。
    private var sinceValidated: (@Sendable () -> Duration)?
    private let clock: any Clock<Duration>
    private var verifying: Task<Outcome, Never>?

    /// 確かめた結果。確かめられなかったときは有効として扱うが、有効と分かったわけではないので、次の401ですぐ確かめ直す。
    private enum Outcome {
        case verified
        case unverified
        case invalid

        var state: State { self == .invalid ? .invalid : .valid }
    }

    /// - Parameters:
    ///   - clock: 確かめ直さない間を測る。テストでは手で進める時計を渡す。
    ///   - verify: トークンが有効なら返り、無効なら401の`MastodonAPIError`を投げる。
    public init(revalidationInterval: Duration = .seconds(60), clock: any Clock<Duration> = SystemTime.clock, verify: @escaping @Sendable () async throws -> Void) {
        self.revalidationInterval = revalidationInterval
        self.clock = clock
        self.verify = verify
    }

    /// REST APIの401を受けたときに呼ぶ。確かめずに無効にする。
    public func reportUnauthorized() {
        guard state != .invalid else { return }
        state = .invalid
        onChange?(state)
    }

    /// ストリーミングの401を受けたときに呼び、確かめた後の状態を返す。確かめている途中に呼ばれたら、その結果を待つ。
    @discardableResult
    public func reportStreamingUnauthorized() async -> State {
        if state == .invalid { return .invalid }
        if let sinceValidated, sinceValidated() < revalidationInterval { return .valid }
        if let verifying {
            let outcome = await verifying.value
            return state == .invalid ? .invalid : outcome.state
        }
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
        // 確かめている間にREST APIの401で無効になっていたら、確かめた結果で有効に戻さない。
        if state == .invalid { return .invalid }
        if outcome == .verified {
            sinceValidated = stopwatch(on: clock)
        }
        if outcome.state != state {
            state = outcome.state
            onChange?(state)
        }
        return outcome.state
    }
}
