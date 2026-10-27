/// いまの回線の状態。
public struct NetworkConditions: Equatable, Sendable {
    /// 低データモード。
    public var isConstrained: Bool
    /// モバイル通信や、インターネット共有のように通信量に限りのある回線。
    public var isExpensive: Bool

    public init(isConstrained: Bool, isExpensive: Bool) {
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }
}

/// 回線と設定から、質を上げると先読みの通信を送ってよいかを決める（docs/network.mdの「通信の目的」）。
/// 回線の状態を読んで送るかを分けるのは、ここだけにする（`make lint`の`network_conditions_outside_policy`で止める）。
/// 経路ごとに分けると、控える経路と控えない経路が混ざり、新しく足した経路が決まりから漏れるため。
public struct NetworkUsePolicy: Equatable, Sendable {
    public var conditions: NetworkConditions
    /// 設定の「モバイル通信で高画質のサムネイルを使う」。
    public var sendsEnhancementOnExpensiveNetwork: Bool

    public init(conditions: NetworkConditions, sendsEnhancementOnExpensiveNetwork: Bool) {
        self.conditions = conditions
        self.sendsEnhancementOnExpensiveNetwork = sendsEnhancementOnExpensiveNetwork
    }

    /// 質を上げる通信を今送ってよいなら、その目的。低データモードでは、設定によらず送らない。
    public var enhancement: RequestPurpose? {
        guard !conditions.isConstrained, !conditions.isExpensive || sendsEnhancementOnExpensiveNetwork else { return nil }
        return .enhancement(onExpensiveNetwork: sendsEnhancementOnExpensiveNetwork)
    }

    /// 先読みを今送ってよいなら、その目的。Wi-Fiのように、通信量に限りがなく低データモードでもない回線でだけ送る。
    public var prefetch: RequestPurpose? {
        guard !conditions.isConstrained, !conditions.isExpensive else { return nil }
        return .prefetch
    }
}
