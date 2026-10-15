import SciaCore
import UIKit

extension ErrorPresentation {
    /// 文言の下に、補足（ステータスコードなど）を一段小さく薄く添える。補足は調べるときのためのもので、読まなくても分かるようにする。
    func attributedText(prefix: String = "", textStyle: UIFont.TextStyle, color: UIColor = .secondaryLabel) -> NSAttributedString {
        let result = NSMutableAttributedString(string: prefix + message, attributes: [
            .font: UIFont.preferredFont(forTextStyle: textStyle),
            .foregroundColor: color,
        ])
        if let code {
            result.append(NSAttributedString(string: "\n" + code, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption2),
                .foregroundColor: UIColor.tertiaryLabel,
            ]))
        }
        return result
    }
}
