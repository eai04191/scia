import SwiftSyntax

extension Rule {
    // 裏に回った通知を投げたままにすると、UIKitがSwiftUIのスプリングの動きを止めたままにし、あとに走るテストの動きが終わらなくなる。
    static let backgroundNotificationInTest = Rule(
        id: "background_notification_in_test",
        message: "テストで裏に回った状態を作るときは、whileInBackgroundで囲み、終えたら戻った通知を投げさせる",
        appliesTo: { $0.hasPrefix("AppTests/") },
        find: { tree in
            tree.all(MemberAccessExprSyntax.self)
                .filter { $0.declName.baseName.text == "didEnterBackgroundNotification" }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}
