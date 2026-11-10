import UIKit

/// テストで、アプリが裏に回った通知を投げて`body`を走らせ、終えたら戻った通知を投げる。
///
/// 裏に回った通知を受けると、UIKitはSwiftUIのスプリングで動かす`UIView.animate`を、戻った通知が来るまで止める（値も動かず、終わりの処理も呼ばれない。裏に回る前にスプリングの動きを一度でも走らせたプロセスで起きる。アプリのテストで確かめた）。
/// テストは1つのプロセスで順に走るので、投げたままにすると、あとに走るテストのスプリングの動きがどれも終わらなくなる。
@MainActor
func whileInBackground(_ body: () throws -> Void) rethrows {
    // scialint:disable:next background_notification_in_test
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
    defer { NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared) }
    try body()
}
