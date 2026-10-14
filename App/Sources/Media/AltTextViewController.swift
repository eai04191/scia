import UIKit

/// 添付ファイルの代替テキストの全文。ビューアの下の説明は高さに上限があり文字を選べないため、
/// 長い説明を読んだり一部をコピーしたりするときに使う。
final class AltTextViewController: UIViewController {
    let text: String
    private let textView = UITextView()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        title = "代替テキスト"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.text = text
        textView.isEditable = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 16, right: 12)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    /// 半分の高さのシートで出し、引き上げると全画面にする。
    static func sheet(text: String) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: AltTextViewController(text: text))
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }
}
