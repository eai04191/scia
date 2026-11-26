public import Foundation
import Observation

/// デバッグメニューを出すかどうか。Releaseのビルドでは、設定の「情報」の「ビルド」の行を続けて選択して切り替える。
@MainActor
@Observable
public final class DeveloperMode {
    /// 切り替えるのに選択する回数。
    public static let requiredTaps = 7

    public private(set) var isEnabled: Bool

    /// 画面のHDRの余地を表示するか。
    public var showsEDRHeadroom: Bool {
        didSet { defaults.set(showsEDRHeadroom, forKey: Self.showsEDRHeadroomKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isAlwaysEnabled: Bool
    @ObservationIgnored private var taps = 0

    private static let enabledKey = "developerMode.isEnabled"
    private static let showsEDRHeadroomKey = "developerMode.showsEDRHeadroom"

    /// - Parameter isAlwaysEnabled: 選択しなくても常に出す。デバッグ版で使う。選択しても切り替わらない。
    public init(defaults: UserDefaults, isAlwaysEnabled: Bool) {
        self.defaults = defaults
        self.isAlwaysEnabled = isAlwaysEnabled
        let isEnabled = isAlwaysEnabled || defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = isEnabled
        // デバッグ版でオンにしたままReleaseを入れると、消す項目のないメニューの裏で表示が残るため。
        showsEDRHeadroom = isEnabled && defaults.bool(forKey: Self.showsEDRHeadroomKey)
    }

    /// 1回選択したことを数える。必要な回数に達したら切り替えて、trueを返す。
    public func registerTap() -> Bool {
        guard !isAlwaysEnabled else { return false }
        taps += 1
        guard taps >= Self.requiredTaps else { return false }
        taps = 0
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.enabledKey)
        // デバッグメニューがなくなると、オフにする項目もなくなるため。
        if !isEnabled {
            showsEDRHeadroom = false
        }
        return true
    }

    /// 数えた回数をリセットする。その行のある画面を離れたときに呼ぶ。
    public func resetTaps() {
        taps = 0
    }
}
