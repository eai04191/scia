import Network
import Observation
import SciaCore

/// 回線の状態を見張る。変化はObservationで購読できる。
@MainActor
@Observable
final class NetworkConditionsMonitor {
    private(set) var conditions = NetworkConditions(isConstrained: false, isExpensive: false)
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                let conditions = NetworkConditions(isConstrained: path.isConstrained, isExpensive: path.isExpensive)
                if self?.conditions != conditions {
                    self?.conditions = conditions
                }
            }
        }
        // 通知をメインスレッドで受け、そのまま状態を変える。
        monitor.start(queue: .main)
    }
}
