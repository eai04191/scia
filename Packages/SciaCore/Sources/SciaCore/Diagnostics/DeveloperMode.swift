public import Foundation
import Observation

/// デバッグメニューを出すかどうか。Releaseのビルドでは、設定の「情報」の「ビルド」の行を続けて押して切り替える。
@MainActor
@Observable
public final class DeveloperMode {
    /// 切り替えるのに押す回数。
    public static let requiredTaps = 7

    public private(set) var isEnabled: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isAlwaysEnabled: Bool
    @ObservationIgnored private var taps = 0

    private static let enabledKey = "developerMode.isEnabled"

    /// - Parameter isAlwaysEnabled: 押さなくても常に出す。デバッグ版で使う。押しても切り替わらない。
    public init(defaults: UserDefaults, isAlwaysEnabled: Bool) {
        self.defaults = defaults
        self.isAlwaysEnabled = isAlwaysEnabled
        isEnabled = isAlwaysEnabled || defaults.bool(forKey: Self.enabledKey)
    }

    /// 1回押したことを数える。必要な回数に達したら切り替えて、trueを返す。
    public func registerTap() -> Bool {
        guard !isAlwaysEnabled else { return false }
        taps += 1
        guard taps >= Self.requiredTaps else { return false }
        taps = 0
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.enabledKey)
        return true
    }

    /// 数えた回数をリセットする。押す画面を離れたときに呼ぶ。
    public func resetTaps() {
        taps = 0
    }
}
