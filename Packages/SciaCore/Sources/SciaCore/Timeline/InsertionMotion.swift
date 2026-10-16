/// 最上部で新着に追従しているとき、新着を足してから最上部へ動かして見せるか。
public enum InsertionMotion: String, CaseIterable, Sendable {
    /// 端末の「視差効果を減らす」がオンなら動かさず、オフなら動かす。
    case followsSystem
    case animated
    case instant

    /// - Parameter reducesMotion: 端末の「視差効果を減らす」がオンか。
    public func animates(reducesMotion: Bool) -> Bool {
        switch self {
        case .followsSystem: !reducesMotion
        case .animated: true
        case .instant: false
        }
    }
}
