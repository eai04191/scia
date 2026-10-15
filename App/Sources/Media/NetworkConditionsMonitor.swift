import Network
import Observation
import SciaCore

/// 回線の状態を見張る。変化はObservationで購読できる。
@MainActor
@Observable
final class NetworkConditionsMonitor {
    private(set) var conditions = NetworkConditions(isConstrained: false, isExpensive: false)
    /// 経路がつながっていない状態から、つながった状態に戻った回数。戻ったことをきっかけに読み込みをやり直すためだけに使う。
    /// 「つながっていないから通信しない」判断には使わない。つながったと出ても、サーバーに届くとは限らないため。
    private(set) var recoveryCount = 0
    @ObservationIgnored private var isSatisfied = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let conditions = NetworkConditions(isConstrained: path.isConstrained, isExpensive: path.isExpensive)
                if self.conditions != conditions {
                    self.conditions = conditions
                }
                let isSatisfied = path.status == .satisfied
                if isSatisfied, !self.isSatisfied {
                    self.recoveryCount += 1
                }
                self.isSatisfied = isSatisfied
            }
        }
        // 通知をメインスレッドで受け、そのまま状態を変える。
        monitor.start(queue: .main)
    }
}
