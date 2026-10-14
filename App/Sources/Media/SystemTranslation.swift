import SwiftUI
import Translation
import UIKit

/// システムの翻訳シートを出す。
///
/// 翻訳シートはSwiftUIの`translationPresentation`でしか出せないため、出す画面に見えないSwiftUIのビューを置き、そこから出させる。
@MainActor
final class SystemTranslation {
    private let request = TranslationRequest()

    /// 翻訳シートを出している、または出そうとしている。
    var isPresented: Bool { request.isPresented }

    /// `parent`の画面に、翻訳シートを出すための見えないビューを置く。大きさを持たず、触れても反応しない。
    func install(in parent: UIViewController) {
        let host = UIHostingController(rootView: TranslationPresenter(request: request))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = .zero
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
    }

    /// `text`を翻訳シートで訳す。
    func present(_ text: String) {
        request.text = text
        request.isPresented = true
    }
}

/// UIKitから、SwiftUIの翻訳シートを出すための状態。
@MainActor
@Observable
private final class TranslationRequest {
    var text = ""
    var isPresented = false
}

/// 翻訳シートを出すだけの、見えないビュー。
private struct TranslationPresenter: View {
    @Bindable var request: TranslationRequest

    var body: some View {
        Color.clear.translationPresentation(isPresented: $request.isPresented, text: request.text)
    }
}
