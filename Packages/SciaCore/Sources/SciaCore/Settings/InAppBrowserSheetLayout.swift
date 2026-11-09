/// アプリ内のSafariのシートの止まる位置。
public enum InAppBrowserDetent: String, Hashable, Sendable {
    case collapsed
    case medium
    case large
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

    /// 離したときの速さを、この秒数だけ進んだ位置に換えて行き先を決める。
    private static let projectionSeconds = 0.15

    public init(collapsed: Double?, medium: Double?, large: Double) {
        self.collapsed = collapsed
        self.medium = medium
        self.large = large
    }

    /// 高さが小さい順。
    public var detents: [InAppBrowserDetent] {
        [collapsed.map { _ in .collapsed }, medium.map { _ in .medium }, .large].compactMap(\.self)
    }

    /// `detent`がこの画面にないときは全画面の高さを返す。
    public func height(of detent: InAppBrowserDetent) -> Double {
        switch detent {
        case .collapsed: collapsed ?? large
        case .medium: medium ?? large
        case .large: large
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
