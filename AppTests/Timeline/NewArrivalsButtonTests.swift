import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 新着ボタンの出し入れ。`isHidden`は動かないため、濃さで出し入れし、消え終えてから隠す。
@Suite(.scratch)
@MainActor
struct NewArrivalsButtonTests {
    private func button(in harness: TimelineHarness) throws -> UIButton {
        try #require(harness.viewController.view.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel?.hasSuffix("の新着") == true })
    }

    /// 出すときは、見えるようにして、濃くする向きにする。
    @Test func showsWhenThereAreArrivals() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        harness.viewController.setUnreadCount(3)
        let button = try button(in: harness)

        #expect(!button.isHidden)
        #expect(button.alpha == 1)
        #expect(button.isUserInteractionEnabled)
    }

    /// 消すときは、すぐには隠さず、薄くする向きにする。すぐ隠すと1コマで消えるため。隠すのは薄くし終えてから。
    @Test func staysVisibleWhileFadingOut() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.setUnreadCount(3)
        let button = try button(in: harness)

        harness.viewController.setUnreadCount(0)

        #expect(!button.isHidden)
        #expect(button.alpha == 0)
        #expect(!button.isUserInteractionEnabled)
    }

    /// 件数の桁が変わるときは、待っている並べ直しを済ませてから入れ替える。その並べ直しで既読が進み、中から新しい件数で呼ばれたら、
    /// 外の古い件数で上書きしない。
    @Test func keepsCountSetDuringPendingLayout() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.setUnreadCount(3)
        harness.window.layoutIfNeeded()
        let button = try button(in: harness)
        let reporter = LayoutReporter { harness.viewController.setUnreadCount(5) }
        harness.viewController.view.addSubview(reporter)
        reporter.setNeedsLayout()

        harness.viewController.setUnreadCount(12)

        #expect(button.configuration?.title == "5")
        #expect(button.accessibilityLabel == "5件の新着")
    }
}

/// 次に並べたときに一度だけ`action`を呼ぶ。並べ直しの中で既読が進むところに見立てる。
private final class LayoutReporter: UIView {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let action = self.action
        self.action = nil
        action?()
    }
}
