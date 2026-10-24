/// OSが知らせる経路の様子から、回線の状態と、経路がつながっていない状態から戻った回数を追う。
public struct NetworkPathTracker: Equatable, Sendable {
    public private(set) var conditions = NetworkConditions(isConstrained: false, isExpensive: false)
    /// 経路がつながっていない状態から、つながった状態に戻った回数。戻ったことをきっかけに読み込みをやり直すためだけに使う。
    /// 「つながっていないから通信しない」判断には使わない。つながったと出ても、サーバーに届くとは限らないため。
    public private(set) var recoveryCount = 0
    /// 最初はつながっているとみなす。見張り始めてすぐにつながっていると知らされても、戻ったとは数えない。
    private var isSatisfied = true

    public init() {}

    /// OSから経路の様子を受け取る。
    /// - Parameter isSatisfied: 経路がつながっているか。
    public mutating func receive(isSatisfied: Bool, conditions: NetworkConditions) {
        self.conditions = conditions
        if isSatisfied, !self.isSatisfied {
            recoveryCount += 1
        }
        self.isSatisfied = isSatisfied
    }
}
