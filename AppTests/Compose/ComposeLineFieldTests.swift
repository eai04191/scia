import Testing
import UIKit
@testable import Scia

/// 投稿欄の1行の入力欄（注意書き、投票の選択肢）。
@MainActor
@Suite(.failureState)
struct ComposeLineFieldTests {
    /// 空のときも、書いたときと同じ高さを取る。UITextFieldは空のときの高さを今の書体から出さないため、
    /// 文字の大きさの設定が既定と違うと、書き始めたときと消したときに、欄と投稿欄の高さが変わる。
    @Test(arguments: [UIContentSizeCategory.small, .large, .accessibilityLarge])
    func emptyFieldIsAsTallAsFilledField(category: UIContentSizeCategory) {
        let field = ComposeLineField()
        field.font = .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        field.placeholder = "選択肢を追加"

        let empty = field.intrinsicContentSize.height
        field.text = "a"
        let filled = field.intrinsicContentSize.height

        #expect(empty == filled)
    }
}
