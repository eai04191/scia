/// ビューアを下へのスワイプで閉じる操作の判定。距離と速さは画面の高さを基準にし、画像の形で感度が変わらないようにする。
public struct DragToDismiss: Sendable, Equatable {
    /// 指を離したとき、画面の高さに対してこの割合より下へ動かしていれば閉じる。
    public var distanceThreshold: Double
    /// 指を離したとき、下へ毎秒この画面数より速く動かしていれば、距離によらず閉じる。上へこの速さで戻していれば閉じない。
    public var velocityThreshold: Double
    /// 画面の高さぶん下へ動かしたときの画像の倍率。そこまでは動かした距離に比例して縮める。
    public var smallestScale: Double
    /// 画面の高さに対してこの割合だけ下へ動かしたところで、背景が透けきる。
    public var fadeDistance: Double
    /// 閉じずに離したとき、元の位置へ戻す時間（秒）。
    public var restoreDuration: Double

    public init(distanceThreshold: Double, velocityThreshold: Double, smallestScale: Double, fadeDistance: Double, restoreDuration: Double) {
        precondition(fadeDistance > 0, "背景が透けきる距離は正の値にします")
        self.distanceThreshold = distanceThreshold
        self.velocityThreshold = velocityThreshold
        self.smallestScale = smallestScale
        self.fadeDistance = fadeDistance
        self.restoreDuration = restoreDuration
    }

    /// 下へ動かした割合。上へ動かしている間は0、画面の高さぶんで1。
    public func progress(translation: Double, height: Double) -> Double {
        guard height > 0 else { return 0 }
        return min(max(translation / height, 0), 1)
    }

    /// 動かしている間の画像の倍率。
    public func scale(translation: Double, height: Double) -> Double {
        1 - (1 - smallestScale) * progress(translation: translation, height: height)
    }

    /// 動かしている間の背景の不透明度。動かした距離に比例して薄くする。
    public func backgroundAlpha(translation: Double, height: Double) -> Double {
        1 - min(progress(translation: translation, height: height) / fadeDistance, 1)
    }

    /// 指を離したときに閉じるか。
    /// - Parameters:
    ///   - translation: 押した位置から下へ動かした距離。上は負。
    ///   - velocity: 離したときの下向きの速さ（pt/秒）。上は負。
    ///   - height: 画面の高さ。
    public func shouldDismiss(translation: Double, velocity: Double, height: Double) -> Bool {
        guard height > 0 else { return false }
        let velocityInScreens = velocity / height
        if velocityInScreens >= velocityThreshold { return true }
        if velocityInScreens <= -velocityThreshold { return false }
        return translation / height >= distanceThreshold
    }
}
