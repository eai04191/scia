import SwiftUI
import Translation
import UIKit

/// 添付ファイルの代替テキストの全文。ビューアの下の説明は1行で切れて文字も選べないため、
/// 長い説明を読んだり一部をコピーしたりするときに使う。
final class AltTextViewController: UIViewController {
    let text: String
    private let textView = UITextView()
    private let translation = TranslationRequest()

    /// システムの翻訳シートを出している、または出そうとしている。
    var isTranslationPresented: Bool { translation.isPresented }

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
        setContentScrollView(textView, for: .top)
        addTranslationPresenter()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "翻訳", image: UIImage(systemName: "translate"), primaryAction: UIAction { [weak self] _ in
            self?.translate()
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    /// 全文をシステムの翻訳シートで訳す。
    func translate() {
        translation.isPresented = true
    }

    /// システムの翻訳シートはSwiftUIの`translationPresentation`でしか出せないため、見えないSwiftUIのビューを置いてそこから出す。
    private func addTranslationPresenter() {
        let host = UIHostingController(rootView: TranslationPresenter(request: translation, text: text))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = .zero
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
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

/// UIKitのボタンから、SwiftUIの翻訳シートを出すための状態。
@MainActor
@Observable
private final class TranslationRequest {
    var isPresented = false
}

/// 翻訳シートを出すだけの、見えないビュー。
private struct TranslationPresenter: View {
    @Bindable var request: TranslationRequest
    let text: String

    var body: some View {
        Color.clear.translationPresentation(isPresented: $request.isPresented, text: text)
    }
}
