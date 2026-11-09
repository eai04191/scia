/// アプリ内のSafariのシートの止まる位置。
public enum InAppBrowserDetent: String, Hashable, Sendable {
    case collapsed
    case medium
    case large
    /// 引いている途中に指を止めた高さ。ほかの段へ動かすと消える。
    case temporary
}

/// 指を離したあとのシートの行き先。
public enum InAppBrowserSheetRelease: Equatable, Sendable {
    case detent(InAppBrowserDetent)
    case dismiss
}

/// アプリ内のSafariのシートの、止まる位置ごとの高さ（pt、画面の下端からシートの上端まで）。
/// 高さの狭い画面では全画面だけになり、`collapsed`と`medium`はnilになる。
public struct InAppBrowserSheetLayout: Equatable, Sendable {
    public let collapsed: Double?
    public let medium: Double?
    public let large: Double
    public let temporary: Double?

    /// 離したときの速さを、この秒数だけ進んだ位置に換えて行き先を決める。
    private static let projectionSeconds = 0.15

    public init(collapsed: Double?, medium: Double?, large: Double, temporary: Double? = nil) {
        self.collapsed = collapsed
        self.medium = medium
        self.large = large
        self.temporary = temporary
    }

    /// 全画面だけの画面には足さない。
    public func withTemporary(_ height: Double?) -> InAppBrowserSheetLayout {
        guard collapsed != nil else { return self }
        return InAppBrowserSheetLayout(collapsed: collapsed, medium: medium, large: large, temporary: height)
    }

    /// 指を止めた高さから作るスナップ点の高さ。`step`の刻みに揃える。ほかの段から`step`以内なら、その段で足りるので作らない。
    public func temporaryHeight(near height: Double, step: Double) -> Double? {
        guard let collapsed else { return nil }
        let rounded = (height / step).rounded() * step
        guard rounded > collapsed + step, rounded < large - step else { return nil }
        if let medium, abs(rounded - medium) <= step { return nil }
        return rounded
    }

    /// 高さが小さい順。
    public var detents: [InAppBrowserDetent] {
        let candidates: [InAppBrowserDetent?] = [collapsed.map { _ in .collapsed }, medium.map { _ in .medium }, .large, temporary.map { _ in .temporary }]
        return candidates.compactMap(\.self).sorted { height(of: $0) < height(of: $1) }
    }

    /// `detent`がこの画面にないときは全画面の高さを返す。
    public func height(of detent: InAppBrowserDetent) -> Double {
        switch detent {
        case .collapsed: collapsed ?? large
        case .medium: medium ?? large
        case .large: large
        case .temporary: temporary ?? large
        }
    }

    /// 閉じるのは、伏せた段からさらに下げたときだけにする。中くらいの高さから勢いよく下げても、伏せた段で止める。
    /// - Parameters:
    ///   - start: 指でつかんだときの段。
    ///   - velocity: 上へ動いているときに正の速さ（pt/秒）。
    public func release(height: Double, velocity: Double, from start: InAppBrowserDetent) -> InAppBrowserSheetRelease {
        let projected = height + velocity * Self.projectionSeconds
        if start == .collapsed, let collapsed, projected < collapsed / 2 { return .dismiss }
        let nearest = detents.min { abs(self.height(of: $0) - projected) < abs(self.height(of: $1) - projected) }
        return .detent(nearest ?? .large)
    }
}
