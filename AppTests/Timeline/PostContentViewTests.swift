import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct PostContentViewTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline)
    }

    /// 一覧のセルと同じく、大きな高さを目安に、高さを譲れる優先度で測る。
    private func fittingHeight(of configuration: PostContentConfiguration) -> CGFloat {
        configuration.makeContentView().systemLayoutSizeFitting(
            CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func status(content: String, reblogOf original: Status? = nil) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: content, spoilerText: "", url: nil, reblog: original)
    }

    /// 名前の行をベースラインで揃えたスタックは高さが決まらず、目安の高さまで伸びて、セルが落ちたことがある。
    @Test func heightFitsContentWhenMeasuredAgainstHugeTarget() throws {
        let short = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        let long = makeViewController().contentConfiguration(for: try status(content: "<p>" + String(repeating: "長い本文。", count: 40) + "</p>"), base: .cell())

        #expect(fittingHeight(of: short) < 200)
        #expect(fittingHeight(of: long) > fittingHeight(of: short))
    }

    /// 本文が1行でも、アイコンの下に余白を残す。
    @Test func shortBodyKeepsMarginBelowAvatar() throws {
        let configuration = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        let metrics = configuration.metrics

        #expect(fittingHeight(of: configuration) >= metrics.margins.top + metrics.avatarSize + metrics.margins.bottom)
    }

    @Test func boostAddsRowAboveName() throws {
        let original = try status(content: "<p>短い</p>")
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: "200", createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        let controller = makeViewController()

        #expect(fittingHeight(of: controller.contentConfiguration(for: boost, base: .cell())) > fittingHeight(of: controller.contentConfiguration(for: original, base: .cell())))
    }
}
