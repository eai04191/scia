import UIKit

/// 投稿欄から開いたビューアの上の中央に出す、アップロードや代替テキストの送信の状態。済んでいれば出さない。
/// 失敗したときだけ押せ、押すと理由と送り直す操作を出す。押したときの処理は置く側が足す。
final class DraftStatusButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = .glass()
        isHidden = true
        configuration?.imagePadding = 6
        configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline)
        configuration?.titleLineBreakMode = .byTruncatingTail
        configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter status: 投稿欄から開いていなければnil。
    func apply(_ status: ComposeAttachmentStatus?) {
        guard let status, status != .ready else {
            isHidden = true
            return
        }
        let (title, isFailure): (String, Bool) = switch status {
        case .uploading: ("アップロード中", false)
        case .processing: ("サーバーで処理中", false)
        case .sendingDescription: ("代替テキストを送信中", false)
        case .failed: ("アップロードできませんでした", true)
        case .descriptionFailed: ("代替テキストを送信できませんでした", true)
        case .ready: ("", false)
        }
        configuration?.title = title
        configuration?.showsActivityIndicator = !isFailure
        configuration?.image = isFailure ? UIImage(systemName: "exclamationmark.circle.fill") : nil
        isUserInteractionEnabled = isFailure
        accessibilityTraits = isFailure ? .button : .staticText
        accessibilityHint = isFailure ? "理由と、再試行か削除を選べます。" : nil
        isHidden = false
    }
}
