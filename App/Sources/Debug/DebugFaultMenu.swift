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

    /// 戻し方と障害の種類で区切って並べる。
    private static func items(handle: @escaping @MainActor (DebugURL) -> Void) -> [UIMenuElement] {
        [
            UIMenu(title: "起動し直すまで続く", options: .displayInline, children: [
                untilRestart("トークンを無効にする", image: "key.slash", isOn: DebugFaults.isRejectingAsUnauthorized) { handle(.unauthorized) },
                untilRestart("投稿と通知の一部を読めなくする", image: "doc.questionmark", isOn: DebugFaults.isCorruptingListElements) { handle(.unreadable) },
                UIMenu(title: "ない機能にする", image: UIImage(systemName: "nosign"), children: OptionalFeature.allCases.map { feature in
                    untilRestart(feature.rawValue, image: nil, isOn: DebugFaults.isUnsupported(feature)) { handle(.unsupported(feature)) }
                }),
            ]),
            UIMenu(title: "サーバーとストリーミング", options: .displayInline, children: [
                statusMenu(handle: handle),
                toggle("ホームを作り直し中にする", image: "hammer", isOn: DebugFaults.isRegeneratingHome) { isOn in
                    handle(.regenerating(isOn))
                },
                toggle("ストリーミングを切る", image: "antenna.radiowaves.left.and.right.slash", isOn: !DebugFaults.isStreamingOnline) { isOn in
                    handle(.streaming(isOnline: !isOn))
                },
                mediaLimitsMenu(handle: handle),
            ]),
            UIMenu(title: "遅らせる", options: .displayInline, children: [
                toggle("ダウンロードを30秒遅らせる", image: "tortoise", isOn: DebugFaults.slowDownloadDelay != nil) { isOn in
                    handle(.slowDownload(seconds: isOn ? 30 : nil))
                },
                toggle("メニューのアイコンを3秒遅らせる", image: "person.crop.circle.badge.clock", isOn: DebugFaults.slowMenuIconDelay != nil) { isOn in
                    handle(.slowMenuIcons(seconds: isOn ? 3 : nil))
                },
                toggle("プロフィールを探すのを3秒遅らせる", image: "person.crop.circle.badge.questionmark", isOn: DebugFaults.slowLookupDelay != nil) { isOn in
                    handle(.slowLookups(seconds: isOn ? 3 : nil))
                },
            ]),
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

    /// 投稿欄が使うサーバーのメディアの上限を差し替え、送る前に縮める流れを、大きなメディアを用意せずに確かめる。
    /// 下書きのない状態で投稿欄を開いたときから効く。
    private static func mediaLimitsMenu(handle: @escaping @MainActor (DebugURL) -> Void) -> UIMenu {
        let current = DebugFaults.mediaLimitsOverride
        let choices: [(title: String, limits: MediaLimits)] = [
            ("容量", MediaLimits(imageSizeLimit: 1_000_000, imageMatrixLimit: nil, videoSizeLimit: 3_000_000, videoMatrixLimit: nil, videoFrameRateLimit: nil)),
            ("画素数", MediaLimits(imageSizeLimit: nil, imageMatrixLimit: 1_000_000, videoSizeLimit: nil, videoMatrixLimit: 640 * 360, videoFrameRateLimit: nil)),
            ("フレームレート", MediaLimits(imageSizeLimit: nil, imageMatrixLimit: nil, videoSizeLimit: nil, videoMatrixLimit: nil, videoFrameRateLimit: 24)),
        ]
        let subtitles = ["画像1MB、動画3MB", "画像100万画素、動画640×360", "動画24fps"]
        let overrides = zip(choices, subtitles).map { choice, subtitle in
            UIAction(title: choice.title, subtitle: subtitle, state: current == choice.limits ? .on : .off) { _ in
                handle(.mediaLimits(choice.limits))
            }
        }
        let clear = UIAction(title: "サーバーの値に戻す", image: UIImage(systemName: "arrow.uturn.backward"), attributes: current == nil ? .disabled : []) { _ in
            handle(.mediaLimits(nil))
        }
        return UIMenu(
            title: "メディアの上限を小さくする",
            subtitle: "下書きのない投稿欄を開いたときから効く",
            image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
            children: overrides + [UIMenu(options: .displayInline, children: [clear])]
        )
    }

    /// サーバーやプロキシの障害。429と503は、自動の通信を止めて明けたら読み込み直すところを確かめられるよう`Retry-After`も返す。
    private static func statusMenu(handle: @escaping @MainActor (DebugURL) -> Void) -> UIMenu {
        let current = DebugFaults.failingStatus
        let choices: [(statusCode: Int, retryAfter: Int?)] = [(500, nil), (502, nil), (503, 30), (429, 30)]
        let failures = choices.map { choice in
            UIAction(
                title: "\(choice.statusCode)",
                subtitle: choice.retryAfter.map { "Retry-After: \($0)秒" },
                state: current?.statusCode == choice.statusCode && current?.retryAfter == choice.retryAfter && current?.target == .api ? .on : .off
            ) { _ in handle(.status(choice.statusCode, retryAfter: choice.retryAfter, target: .api)) }
        }
        let clear = UIAction(title: "戻す", image: UIImage(systemName: "arrow.uturn.backward"), attributes: current == nil ? .disabled : []) { _ in
            handle(.statusCleared)
        }
        return UIMenu(title: "サーバーのエラーを返す", image: UIImage(systemName: "server.rack"), children: failures + [UIMenu(options: .displayInline, children: [clear])])
    }
}
#endif
