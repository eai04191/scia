#if DEBUG
import Foundation
import os
import ReplayKit
import SciaCore
import UIKit

/// 撮影モードで、アプリ自身の画面をReplayKitで録画する。実機で撮るため。
/// 台本の`record-start`と`record-stop`で始めて止め、Documents/Promo/promo.mp4に書き出す。
/// シミュレーターでもReplayKitは動くが、`simctl io recordVideo`で撮るので、台本は録画を始めない。ReplayKitが使えなければ`unavailable`にして何もしない。
///
/// 録画の状態は、UIテストが読めるよう、ウインドウのaccessibilityIdentifierに`scenario-recorder:<状態>`の形で出す。
/// 画面には何も描かないので、録画に映らない。UIテストは、録画が始まったことと、書き出し終えたことを確かめてから進む。
@MainActor
enum ScenarioRecorder {
    enum State: String {
        case idle
        case unavailable
        case starting
        case recording
        case writing
        case written
        case failed
    }

    private nonisolated static let logger = SciaLog.logger(category: "scenario")

    private static var state = State.idle {
        didSet { publish() }
    }

    /// 書き出す先。`xcrun devicectl device copy from`で取り出す。
    static var outputURL: URL {
        URL.documentsDirectory.appending(path: "Promo/promo.mp4")
    }

    static func start() {
        // 前に撮ったファイルを、今回のものと取り違えて取り出さないよう、始める前に消す。
        do {
            if FileManager.default.fileExists(atPath: outputURL.path()) {
                try FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            fail("remove previous output", error)
            return
        }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            logger.info("scenario recorder unavailable")
            state = .unavailable
            return
        }
        // マイクの音は撮らない。動画の音は編集で重ねる。
        recorder.isMicrophoneEnabled = false
        state = .starting
        recorder.startRecording { error in
            Task { @MainActor in
                if let error {
                    fail("start", error)
                } else {
                    logger.info("scenario recorder started")
                    state = .recording
                }
            }
        }
    }

    static func stop() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording else {
            // 撮れていないのに止めた。シミュレーターのように使えないときは、そのまま。
            logger.error("scenario recorder not recording")
            if state != .unavailable {
                state = .failed
            }
            return
        }
        let url = outputURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            fail("create output directory", error)
            return
        }
        state = .writing
        recorder.stopRecording(withOutput: url) { error in
            Task { @MainActor in
                if let error {
                    fail("stop", error)
                } else {
                    logger.info("scenario recorder wrote \(url.lastPathComponent, privacy: .public)")
                    state = .written
                }
            }
        }
    }

    private static func fail(_ step: String, _ error: any Error) {
        logger.error("scenario recorder \(step, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        state = .failed
    }

    private static func publish() {
        let identifier = "scenario-recorder:\(state.rawValue)"
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.isKeyWindow {
                window.accessibilityIdentifier = identifier
            }
        }
    }
}
#endif
