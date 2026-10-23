import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct AccountRowContentTests {
    private func visibleLabels(in view: UIView) -> [UILabel] {
        view.subviews.filter { !$0.isHidden }.flatMap { subview in
            (subview as? UILabel).map { [$0] } ?? visibleLabels(in: subview)
        }
    }

    /// 大きな文字の設定で名前とハンドルがアイコンより高くなっても、文字を縮めずに行を伸ばす。
    @Test(arguments: [17.0, 40.0])
    func labelsKeepTheirHeight(fontSize: CGFloat) throws {
        let vc = TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
        let account = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: nil)
        var base = UIListContentConfiguration.cell()
        base.textProperties.font = .systemFont(ofSize: fontSize)
        base.secondaryTextProperties.font = .systemFont(ofSize: fontSize * 0.8)
        let view = vc.accountConfiguration(for: account, base: base).makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let labels = visibleLabels(in: view)

        #expect(labels.count == 2)
        for label in labels {
            #expect(label.bounds.height >= label.intrinsicContentSize.height - 0.01, "\(label.attributedText?.string ?? "") label=\(label.bounds) intrinsic=\(label.intrinsicContentSize)")
            #expect(label.frame.maxY <= view.bounds.maxY)
        }
    }
}
