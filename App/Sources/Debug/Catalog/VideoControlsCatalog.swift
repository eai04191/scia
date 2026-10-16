#if DEBUG
import SciaCore
import UIKit

/// 動画のビューアに重ねる、再生の操作の部品（`VideoControlsView`）の状態。ビューアと同じく、画像の上に画面くらいの高さで置く。
/// 代替テキストの帯との重なりは、帯の高さに合わせてシークバーを上げるだけで部品の状態は変わらないため、ダミー投稿の実物で見る。
/// 部品を出しているときにダブルタップしたときやボタンを押したときは、10秒のボタンの矢印を回す動きだけなので、載せずに実物で見る。
enum VideoControlsCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "再生中") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 6, duration: 20), isMuted: false, hasAudio: true))
            },
            CatalogState(title: "止めていて、消音している") {
                controls(VideoControlsView.State(isPlaying: false, time: PlaybackTime(elapsed: 12, duration: 20), isMuted: true, hasAudio: true))
            },
            CatalogState(title: "音声のない動画（消音のボタンを出さない）") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 1, duration: 2), isMuted: false, hasAudio: false))
            },
            CatalogState(title: "1時間を超える動画") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 3725, duration: 5025), isMuted: false, hasAudio: true))
            },
            CatalogState(title: "長押しで2倍速にしている") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 6, duration: 20), isMuted: false, hasAudio: true), fastForwarding: true)
            },
            CatalogState(title: "部品を隠していて、ダブルタップで10秒戻った") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 6, duration: 20), isMuted: false, hasAudio: true), hidden: true, skipped: false)
            },
            CatalogState(title: "長押しで2倍速にしていて、部品を隠している") {
                controls(VideoControlsView.State(isPlaying: true, time: PlaybackTime(elapsed: 6, duration: 20), isMuted: false, hasAudio: true), fastForwarding: true, hidden: true)
            },
        ]
    }

    @MainActor
    /// - Parameter skipped: ダブルタップで進んだ（true）か戻った（false）知らせを出す。本物は短時間で消えるため、カタログでは1時間出したままにする。
    private static func controls(_ state: VideoControlsView.State, fastForwarding: Bool = false, hidden: Bool = false, skipped: Bool? = nil) -> UIView {
        let controls = VideoControlsView()
        controls.apply(state)
        controls.setFastForwarding(fastForwarding)
        controls.setControlsHidden(hidden, animated: false)
        if let skipped {
            controls.showSkipEffect(forward: skipped, duration: 3600)
        }
        // ビューアは暗い表示に固定しているため、ガラスの色合いを合わせる。
        controls.overrideUserInterfaceStyle = .dark
        return CatalogBackdrop.image(controls) { backdrop, controls in
            [
                controls.topAnchor.constraint(equalTo: backdrop.topAnchor),
                controls.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
                controls.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                controls.heightAnchor.constraint(equalToConstant: 420),
            ]
        }
    }
}
#endif
