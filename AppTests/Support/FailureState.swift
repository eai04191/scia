import SciaCore
import Testing
import UIKit
@testable import Scia

extension Trait where Self == IssueHandlingTrait {
    /// テストが落ちたら、落ちた時点のウィンドウ、フォーカス、画面の状態ダンプを、失敗のメッセージに添える。
    /// 確認に書いた式の値だけでは、たまにしか落ちないテストの原因を、落ちた回の記録から調べられないため。
    static var failureState: Self {
        .compactMapIssues { issue in
            // suiteに付けたtraitは、suiteとその中のテストの両方で働く。1件の失敗に2回添えない。
            guard !issue.comments.contains(where: { $0.rawValue.hasPrefix(FailureState.heading) }) else { return issue }
            var issue = issue
            issue.comments.append(Comment(rawValue: FailureState.capture()))
            return issue
        }
    }
}

enum FailureState {
    static let heading = "落ちた時点の状態:"

    /// 失敗が記録されたスレッドで呼ばれる。UIKitの状態はメインスレッドでしか読めないので、ほかのスレッドで記録された失敗には添えない。
    static func capture() -> String {
        guard Thread.isMainThread else { return "\(heading) メインスレッドの外で記録された失敗なので、読んでいません" }
        return MainActor.assumeIsolated { describe() }
    }

    @MainActor
    static func describe() -> String {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var lines = [heading, "アプリ: \(describe(UIApplication.shared.applicationState)) ウィンドウ\(windows.count)枚"]
        for window in windows {
            lines.append("- \(describe(window))")
            if let responder = firstResponder(in: window) {
                lines.append("  フォーカス: \(describe(responder))")
            }
        }
        for dump in AppDependencies.stateDumps.dumpAll() {
            lines.append("[\(dump.name)]")
            lines.append(dump.text)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func describe(_ window: UIWindow) -> String {
        var controllers: [String] = []
        var controller = window.rootViewController
        while let current = controller {
            controllers.append("\(type(of: current))")
            controller = current.presentedViewController
        }
        return "\(type(of: window)) key=\(window.isKeyWindow) hidden=\(window.isHidden) level=\(window.windowLevel.rawValue) 画面=\(controllers.joined(separator: " > "))"
    }

    @MainActor
    private static func describe(_ responder: UIView) -> String {
        var text = "\(type(of: responder))"
        if let input = responder as? any UITextInput {
            let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument).flatMap { input.text(in: $0) } ?? ""
            text += " text=\(all.prefix(200)) marked=\(input.markedTextRange != nil) 入力の言語=\(responder.textInputMode?.primaryLanguage ?? "nil")"
        }
        return text
    }

    @MainActor
    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
