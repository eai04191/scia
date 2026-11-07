import os
@_spi(FailureDisplay) import SciaCore
import SwiftUI
import UIKit

// 失敗の理由を出す部品。理由（`ErrorPresentation`）の文言はSPIで、このファイルからしか読めない。
// 理由を出すところがどこでもこの部品を通るので、ログアウトされたアカウントがあれば、どこでも「ログインし直す」ボタンが付く。
// ほかのファイルでSPIをimportする書き方は、`make lint`の`failure_reason_outside_display`で止める。

/// ログアウトされたアカウントにログインし直す。ウインドウを持つ`SceneDelegate`が受け持つ。
@MainActor
protocol AccountReauthenticating: AnyObject {
    func reauthenticate(_ account: RequestAccount)
}

/// 「ログインし直す」を押した部品がのっているウインドウのシーンに、ログインし直しを頼む。ウインドウが複数あっても、押したウインドウで認可画面を出すため。
@MainActor
private func logIn(_ account: RequestAccount, in scene: UIWindowScene?) {
    guard let reauthenticating = scene?.delegate as? any AccountReauthenticating else {
        failureDisplayLogger.error("log in again ignored without scene")
        return
    }
    reauthenticating.reauthenticate(account)
}

private let failureDisplayLogger = SciaLog.logger(category: "failureDisplay")

/// 失敗の理由の部品の外で、ログアウトされたアカウントにログインし直す。理由の文字しか置けないメニューに足した「ログインし直す」の項目から呼ぶ。
enum FailureRecovery {
    /// `view`がのっているウインドウのシーンで、`account`にログインし直す。
    @MainActor
    static func logIn(_ account: RequestAccount, from view: UIView?) {
        Scia.logIn(account, in: view?.window?.windowScene)
    }
}

/// 部品がのっているウインドウのシーンを覚える、見えないビュー。アラートのボタンが呼ばれるときには、アラートはもうウインドウから外れているため、出ている間に覚えておく。
private final class SceneTracker: UIView {
    private(set) weak var scene: UIWindowScene?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let windowScene = window?.windowScene {
            scene = windowScene
        }
    }
}

/// SwiftUIの部品がのっているウインドウのシーンを、`SceneTracker`で覚えるもの。
@MainActor
private final class SceneBox {
    let tracker = SceneTracker()
    var scene: UIWindowScene? { tracker.scene }
}

private struct SceneTrackerView: UIViewRepresentable {
    let box: SceneBox

    func makeUIView(context: Context) -> UIView { box.tracker }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { .zero }
}

private let logInTitle = "ログインし直す"

extension UIAlertController {
    /// 失敗の理由を出すアラート。理由にログアウトされたアカウントがあれば、「ログインし直す」を添える。
    /// - Parameters:
    ///   - actions: 理由のほかに選ばせる操作（再試行など）。「ログインし直す」のあと、閉じるボタンの前に並べる。
    ///   - cancelTitle: 閉じるボタンの名前。
    ///   - onClose: どのボタンで閉じても呼ぶ。
    static func failure(
        title: String,
        reason: ErrorPresentation,
        actions: [UIAlertAction] = [],
        cancelTitle: String = "OK",
        onClose: (@MainActor () -> Void)? = nil
    ) -> UIAlertController {
        let alert = UIAlertController(title: title, message: reason.text, preferredStyle: .alert)
        if let account = reason.loggedOutAccount {
            let tracker = SceneTracker()
            tracker.isHidden = true
            alert.view.addSubview(tracker)
            alert.addAction(UIAlertAction(title: logInTitle, style: .default) { [tracker] _ in
                onClose?()
                logIn(account, in: tracker.scene)
            })
        }
        for action in actions {
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in onClose?() })
        return alert
    }
}

/// UIKitの画面の中に出す失敗の理由。理由の文字と、ログアウトされたアカウントがあれば「ログインし直す」ボタンを縦に並べる。
final class FailureReasonStackView: UIStackView {
    let label = UILabel()
    private lazy var logInButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = logInTitle
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self, let account = loggedOutAccount else { return }
            logIn(account, in: window?.windowScene)
        })
    }()
    private var loggedOutAccount: RequestAccount?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = 4
        label.numberOfLines = 0
        addArrangedSubview(label)
        addArrangedSubview(logInButton)
        logInButton.isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `reason`を出す。`lead`は、何ができなかったかの一文で、理由の前の行に置く。
    func show(_ reason: ErrorPresentation, lead: String? = nil) {
        label.text = [lead, reason.text].compactMap(\.self).joined(separator: "\n")
        loggedOutAccount = reason.loggedOutAccount
        logInButton.isHidden = reason.loggedOutAccount == nil
    }
}

/// 画面の中に出す失敗の理由（SwiftUI）。理由にログアウトされたアカウントがあれば、「ログインし直す」ボタンを添える。
struct FailureReason: View {
    let reason: ErrorPresentation
    @State private var box = SceneBox()
    /// 何ができなかったかの一文。理由の前に置く。
    var lead: String?
    /// 補足（「HTTP 401」など）も添えるか。小さく出す場所では添えない。
    var includesCode = true

    var body: some View {
        let shown = includesCode ? reason.text : reason.message
        // ウインドウを覚えるビューは、理由の文字に付ける。ボタンに付けると、Formの行の幅いっぱいに押せるボタンではなくなるため。
        Text(lead.map { "\($0)\n\(shown)" } ?? shown)
            .background(SceneTrackerView(box: box))
        if let account = reason.loggedOutAccount {
            // 理由の文字に付けた色（失敗の赤など）を引き継がず、押せる行としてアクセントカラーで出す。
            Button(logInTitle) { logIn(account, in: box.scene) }
                .foregroundStyle(.tint)
        }
    }
}

/// 行そのものが押せるボタンのところ（押すと読み直す補完の候補の失敗など）に置く、失敗の理由の行。
/// ログアウトされていれば、押すと読み直す代わりに、そのアカウントでログインし直す。ログインし直さないと読み直しても同じ失敗になるため。
struct FailureRowButton<Label: View, Style: ButtonStyle>: View {
    let reason: ErrorPresentation
    let retry: () -> Void
    let style: Style
    /// 理由の文字と、押すとログインし直すかを受け取り、行の中身を作る。
    @ViewBuilder let label: (_ reason: String, _ logsIn: Bool) -> Label
    @State private var box = SceneBox()

    var body: some View {
        let logsIn = reason.loggedOutAccount != nil
        Button {
            if let account = reason.loggedOutAccount {
                logIn(account, in: box.scene)
            } else {
                retry()
            }
        } label: {
            label(reason.text, logsIn)
        }
        .buttonStyle(style)
        .background(SceneTrackerView(box: box))
        .accessibilityHint(logsIn ? "ログインし直します" : "再読み込みします")
    }
}

extension View {
    /// 失敗の理由を出すアラート（SwiftUI）。`reason`がnilでなくなったら出し、閉じたらnilに戻す。ログアウトされたアカウントがあれば「ログインし直す」を添える。
    func failureAlert(_ title: String, reason: Binding<ErrorPresentation?>) -> some View {
        modifier(FailureAlertModifier(title: title, reason: reason))
    }
}

private struct FailureAlertModifier: ViewModifier {
    let title: String
    @Binding var reason: ErrorPresentation?
    @State private var box = SceneBox()

    func body(content: Content) -> some View {
        content
            .background(SceneTrackerView(box: box))
            .alert(title, isPresented: Binding { reason != nil } set: { if !$0 { reason = nil } }, presenting: reason) { shown in
                if let account = shown.loggedOutAccount {
                    Button(logInTitle) { logIn(account, in: box.scene) }
                }
                Button("OK", role: .cancel) {}
            } message: { shown in
                Text(shown.text)
            }
    }
}

enum FailureText {
    /// ボタンを並べられないところ（押すと読み直す行の説明など）に出す理由の文字。「ログインし直す」は付かないので、
    /// 401にならない通信か、401になりうるのが今のアカウントだけで、ログインし直しの段から行えるところに限って使う。
    static func withoutLogIn(_ reason: ErrorPresentation) -> String {
        reason.text
    }
}

extension ErrorPresentation {
    /// 文言の下に、補足（ステータスコードなど）を一段小さく薄く添える。補足は調べるときのためのもので、読まなくても分かるようにする。
    /// 「ログインし直す」は付かないので、`FailureText.withoutLogIn`と同じく、ボタンを並べられないところだけで使う。
    /// タイムラインの読み込みの失敗のように、401になると再試行のボタンがログインし直しに替わるところ（`SessionController.showReauthenticationPrompt`）に当たる。
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
