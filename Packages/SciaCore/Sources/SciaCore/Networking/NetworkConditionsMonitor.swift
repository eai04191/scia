import Network
public import Observation

/// 回線の状態を見張る。変化はObservationで購読できる。OSの知らせ（`NWPathMonitor`）を`NetworkPathTracker`に渡し、その結果を出すだけにする。
/// 回線で送るかを決めるのは`NetworkUsePolicy`なので、回線の状態は`usePolicy(settings:)`を通して渡す。
/// アプリで1つ作り、どのアカウントでも共有する。電波が戻った回数（`recoveryCount`）は`AccountSession.observeRecoveries(networkRecoveryCount:)`に渡す。
@MainActor
@Observable
public final class NetworkConditionsMonitor {
    private var conditions = NetworkConditions(isConstrained: false, isExpensive: false)
    /// 経路がつながっていない状態から、つながった状態に戻った回数。使い方は`NetworkPathTracker.recoveryCount`にある。
    public private(set) var recoveryCount = 0
    @ObservationIgnored private var tracker = NetworkPathTracker()
    @ObservationIgnored private let monitor: NWPathMonitor?

    /// 作ったときから見張る。
    public convenience init() {
        let monitor = NWPathMonitor()
        self.init(monitor: monitor)
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.receive(isSatisfied: path.status == .satisfied, conditions: NetworkConditions(isConstrained: path.isConstrained, isExpensive: path.isExpensive))
            }
        }
        // 通知をメインスレッドで受け、そのまま状態を変える。
        monitor.start(queue: .main)
    }

    /// テストで、OSの知らせの代わりに`receive(isSatisfied:conditions:)`で状態を渡すときは、`monitor`をnilにして作る。
    init(monitor: NWPathMonitor?) {
        self.monitor = monitor
    }

    /// 今の回線と設定で、質を上げると先読みの通信を送ってよいかの決まり。Observationの中で読めば、回線か設定が変わったときに知らされる。
    public func usePolicy(settings: AppSettings) -> NetworkUsePolicy {
        NetworkUsePolicy(conditions: conditions, sendsEnhancementOnExpensiveNetwork: settings.usesOriginalThumbnailsOnExpensiveNetwork)
    }

    /// タイムラインのサムネイルに、プレビュー画像と元の画像のどちらを読むかを決めるときの条件（`MediaThumbnailSelection`）。
    /// 今の回線と設定で、元の画像を読んでよいかと先読みしてよいかを決め、プレビュー画像を引き伸ばしてよい倍率はチューニングから読む。
    /// Observationの中で読めば、回線、設定、チューニングが変わったときに知らされる。
    public func thumbnailPolicy(settings: AppSettings, tuning: TuningStore) -> MediaThumbnailPolicy {
        MediaThumbnailPolicy(usePolicy: usePolicy(settings: settings), tuning: tuning)
    }

    /// 変わったものだけを書き換え、変わっていない値の購読者を起こさない。
    func receive(isSatisfied: Bool, conditions: NetworkConditions) {
        tracker.receive(isSatisfied: isSatisfied, conditions: conditions)
        if self.conditions != tracker.conditions {
            self.conditions = tracker.conditions
        }
        if recoveryCount != tracker.recoveryCount {
            recoveryCount = tracker.recoveryCount
        }
    }
}
