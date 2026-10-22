#if DEBUG
import os
import SciaCore
import UIKit

/// 低い段のシートの中で入力欄にキーボードを出したとき、シートがどう動くかを確かめる試作。`scia-debug://sheet-keyboard`で開く。
/// 絵文字のパレットをシートにするか決めるために使う。上に検索欄、下に絵文字の代わりの色の帯を置き、帯の下端をシートの中のキーボードに沿う枠に付ける。
/// シートの枠、キーボードの枠、キーボードに沿う枠を、画面とinfoのログ（`sheetKeyboard`）に出す。
final class SheetKeyboardExperiment: UIViewController {
    private let field = UISearchTextField()
    private let band = UIView()
    private let status = UILabel()
    private let logger = SciaLog.logger(category: "sheetKeyboard")
    private var keyboardFrame: CGRect = .zero
    private static let lowDetent = UISheetPresentationController.Detent.Identifier("low")
    /// 検索欄にキーボードを出したときに選ぶ段。キーボードの上に絵文字の数段分（200pt）だけ出し、投稿欄のバーが見えるようにする。
    private static let searchDetent = UISheetPresentationController.Detent.Identifier("search")
    /// 画面の下端からの、検索の段のシートの上端までの高さ。キーボードの高さが届いたら決め直す。
    private static var searchHeight: CGFloat = 336 + 200

    /// - Parameter lowHeight: 低いときのシートの高さ。画面の下の安全領域は含まない。
    static func present(from host: UIViewController, lowHeight: CGFloat) {
        let controller = SheetKeyboardExperiment()
        if let sheet = controller.sheetPresentationController {
            let low = UISheetPresentationController.Detent.custom(identifier: lowDetent) { _ in lowHeight }
            // 段の高さは下の安全領域を含まないので、その分を引く。
            let search = UISheetPresentationController.Detent.custom(identifier: searchDetent) { _ in
                searchHeight - (host.view.window?.safeAreaInsets.bottom ?? 0)
            }
            sheet.detents = [low, search, .large()]
            sheet.selectedDetentIdentifier = lowDetent
            sheet.largestUndimmedDetentIdentifier = lowDetent
            sheet.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "絵文字を検索"
        field.accessibilityLabel = "絵文字を検索"
        field.delegate = self
        band.translatesAutoresizingMaskIntoConstraints = false
        band.backgroundColor = .systemPink.withAlphaComponent(0.4)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.numberOfLines = 0
        status.accessibilityIdentifier = "sheetKeyboardStatus"
        view.addSubview(field)
        view.addSubview(band)
        band.addSubview(status)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            band.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            status.topAnchor.constraint(equalTo: band.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -16),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        report("layout")
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        if keyboardFrame.height > 100 {
            Self.searchHeight = keyboardFrame.height + 200
            sheetPresentationController?.invalidateDetents()
        }
        report("keyboard")
    }

    private func report(_ event: String) {
        guard let window = view.window else { return }
        let sheetFrame = view.convert(view.bounds, to: window)
        let guideFrame = view.keyboardLayoutGuide.layoutFrame
        let detent = sheetPresentationController?.selectedDetentIdentifier?.rawValue ?? "nil"
        let text = "sheet \(Int(sheetFrame.minY))..\(Int(sheetFrame.maxY)) h=\(Int(sheetFrame.height))\nkeyboard top=\(Int(keyboardFrame.minY)) h=\(Int(keyboardFrame.height))\nguide h=\(Int(guideFrame.height)) band h=\(Int(band.bounds.height))\ndetent \(detent)"
        status.text = text
        logger.info("\(event, privacy: .public): \(text.replacingOccurrences(of: "\n", with: " | "), privacy: .public)")
    }
}
extension SheetKeyboardExperiment: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = Self.searchDetent
        }
        report("began")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = Self.lowDetent
        }
        return false
    }
}
#endif
