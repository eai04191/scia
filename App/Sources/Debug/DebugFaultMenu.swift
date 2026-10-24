#if DEBUG
import SciaCore
import UIKit

/// `scia-debug://`で起こす障害を、デバッグメニューから起こす。URLを開けない実機で確かめるため。
/// 開くたびに`DebugFaults`の今の状態を読んで組み立て、起こしている障害にチェックマークを付ける。
@MainActor
enum DebugFaultMenu {
    /// - Parameter handle: 選んだ操作を、URLで届いたときと同じ処理に渡す。
    static func make(handle: @escaping @MainActor (DebugURL) -> Void) -> UIMenu {
        UIMenu(title: "障害を起こす", image: UIImage(systemName: "exclamationmark.triangle"), children: [
            UIDeferredMenuElement.uncached { completion in
                completion(items(handle: handle))
            },
        ])
    }

    private static func items(handle: @escaping @MainActor (DebugURL) -> Void) -> [UIMenuElement] {
        [
            untilRestart("トークンを無効にする", image: "key.slash", isOn: DebugFaults.isRejectingAsUnauthorized) { handle(.unauthorized) },
            untilRestart("投稿と通知の一部を読めなくする", image: "doc.questionmark", isOn: DebugFaults.isCorruptingListElements) { handle(.unreadable) },
            statusMenu(handle: handle),
            UIMenu(title: "ない機能にする", image: UIImage(systemName: "nosign"), children: OptionalFeature.allCases.map { feature in
                untilRestart(feature.rawValue, image: nil, isOn: DebugFaults.isUnsupported(feature)) { handle(.unsupported(feature)) }
            }),
            toggle("ホームを作り直し中にする", image: "hammer", isOn: DebugFaults.isRegeneratingHome) { isOn in
                handle(.regenerating(isOn))
            },
            toggle("ストリーミングを切る", image: "antenna.radiowaves.left.and.right.slash", isOn: !DebugFaults.isStreamingOnline) { isOn in
                handle(.streaming(isOnline: !isOn))
            },
            toggle("ダウンロードを30秒遅らせる", image: "tortoise", isOn: DebugFaults.slowDownloadDelay != nil) { isOn in
                handle(.slowDownload(seconds: isOn ? 30 : nil))
            },
            toggle("メニューのアイコンを3秒遅らせる", image: "person.crop.circle.badge.clock", isOn: DebugFaults.slowMenuIconDelay != nil) { isOn in
                handle(.slowMenuIcons(seconds: isOn ? 3 : nil))
            },
        ]
    }

    /// 戻す操作がなく、起動し直すまで続く障害。起こした後はチェックマークを付けて押せなくする。
    private static func untilRestart(_ title: String, image: String?, isOn: Bool, action: @escaping @MainActor () -> Void) -> UIAction {
        UIAction(
            title: title,
            subtitle: isOn ? "起動し直すと戻る" : nil,
            image: image.flatMap { UIImage(systemName: $0) },
            attributes: isOn ? .disabled : [],
            state: isOn ? .on : .off
        ) { _ in action() }
    }

    /// 選び直すと戻せる障害。
    private static func toggle(_ title: String, image: String, isOn: Bool, action: @escaping @MainActor (_ isOn: Bool) -> Void) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: image), state: isOn ? .on : .off) { _ in action(!isOn) }
    }

    /// サーバーやプロキシの障害。429と503は、自動の通信を止めて明けたら読み込み直すところを確かめられるよう`Retry-After`も返す。
    private static func statusMenu(handle: @escaping @MainActor (DebugURL) -> Void) -> UIMenu {
        let current = DebugFaults.failingStatus
        let choices: [(statusCode: Int, retryAfter: Int?)] = [(500, nil), (502, nil), (503, 30), (429, 30)]
        let failures = choices.map { choice in
            UIAction(
                title: "\(choice.statusCode)",
                subtitle: choice.retryAfter.map { "Retry-After: \($0)秒" },
                state: current?.statusCode == choice.statusCode && current?.retryAfter == choice.retryAfter ? .on : .off
            ) { _ in handle(.status(choice.statusCode, retryAfter: choice.retryAfter)) }
        }
        let clear = UIAction(title: "戻す", image: UIImage(systemName: "arrow.uturn.backward"), attributes: current == nil ? .disabled : []) { _ in
            handle(.statusCleared)
        }
        return UIMenu(title: "サーバーのエラーを返す", image: UIImage(systemName: "server.rack"), children: failures + [UIMenu(options: .displayInline, children: [clear])])
    }
}
#endif
