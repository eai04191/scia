import SciaCore
import UIKit

/// 添付ファイルの代替テキストの全文。ビューアの下の説明は1行で切れて文字も選べないため、
/// 長い説明を読んだり一部をコピーしたりするときに使う。
final class AltTextViewController: UIViewController {
    let text: String
    private let settings: AppSettings
    private let textView = GlyphLanguageTextView()
    private let translation = SystemTranslation()

    /// システムの翻訳シートを出している、または出そうとしている。
    var isTranslationPresented: Bool { translation.isPresented }

    init(text: String, settings: AppSettings = AppDependencies.settings) {
        self.text = text
        self.settings = settings
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
        // 人が書いた代替テキストは言語が分からないため、設定の字形で描く。
        textView.followGlyphLanguage(of: settings)
        textView.text = text
        textView.isEditable = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 16, right: 12)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        // ナビゲーションバーがどのスクロールビューに合わせるかを明示する。翻訳シートを出すための見えないSwiftUIのビューを一番奥に置いたら、
        // バーが本文を見つけられず、本文の先頭がバーの下に潜った。今は本文の上に置いているが、置き場所で壊れないよう明示したままにする。
        setContentScrollView(textView, for: .top)
        translation.install(in: self)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "翻訳", image: UIImage(systemName: "translate"), primaryAction: UIAction { [weak self] _ in
            self?.translate()
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    /// 全文をシステムの翻訳シートで訳す。
    func translate() {
        translation.present(text)
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
