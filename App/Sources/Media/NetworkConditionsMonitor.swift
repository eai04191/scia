import Network
import Observation
import SciaCore

/// 回線の状態を見張る。変化はObservationで購読できる。OSの知らせを`NetworkPathTracker`に渡し、その結果を出すだけにする。
/// 回線で送るかを決めるのは`NetworkUsePolicy`なので、回線の状態は`usePolicy(settings:)`を通して渡す。
@MainActor
@Observable
final class NetworkConditionsMonitor {
    private var conditions = NetworkConditions(isConstrained: false, isExpensive: false)
    /// 経路がつながっていない状態から、つながった状態に戻った回数。使い方は`NetworkPathTracker.recoveryCount`にある。
    private(set) var recoveryCount = 0
    @ObservationIgnored private var tracker = NetworkPathTracker()
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.receive(isSatisfied: path.status == .satisfied, conditions: NetworkConditions(isConstrained: path.isConstrained, isExpensive: path.isExpensive))
            }
        }
        // 通知をメインスレッドで受け、そのまま状態を変える。
        monitor.start(queue: .main)
    }

    /// 今の回線と設定で、質を上げると先読みの通信を送ってよいかの決まり。Observationの中で読めば、回線か設定が変わったときに知らされる。
    func usePolicy(settings: AppSettings) -> NetworkUsePolicy {
        NetworkUsePolicy(conditions: conditions, sendsEnhancementOnExpensiveNetwork: settings.usesOriginalThumbnailsOnExpensiveNetwork)
    }

    /// 変わったものだけを書き換え、変わっていない値の購読者を起こさない。
    private func receive(isSatisfied: Bool, conditions: NetworkConditions) {
        tracker.receive(isSatisfied: isSatisfied, conditions: conditions)
        if self.conditions != tracker.conditions {
            self.conditions = tracker.conditions
        }
        if recoveryCount != tracker.recoveryCount {
            recoveryCount = tracker.recoveryCount
        }
    }
}
