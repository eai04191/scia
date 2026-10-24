public import Foundation

/// 実物の時計と今の日付。時間をおく処理と今の日付を使う処理は、既定値としてここを参照し、テストでは手で進める時計や決まった日付に差し替える。
/// 実際の時間に触れてよいのは、このファイルとアプリの`AppDependencies`だけにする（`make lint`の`direct_time_access`で止める）。
public enum SystemTime {
    /// 時間をおく処理に渡す、実際の時計。
    public static let clock: any Clock<Duration> = ContinuousClock()

    /// 今の日付。
    public static func now() -> Date {
        Date()
    }
}
