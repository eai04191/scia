#if DEBUG
import Foundation
import os
import SciaCore

/// プロモーション動画の素材を撮るための撮影モード。起動の引数`-scenario <台本の名前>`で入る。
/// 外部と通信せず、台本のサーバーに答えさせる。台本の流れと撮り方はdocs/promo-video.mdにある。
@MainActor
enum ScenarioMode {
    /// 撮影モードで起動したときの、台本のサーバー。撮影モードでなければnil。
    static let server: ScenarioServer? = {
        // `-scenario <名前>`は、起動の引数としてUserDefaultsの引数のドメインに入る。
        guard let name = UserDefaults.standard.string(forKey: "scenario") else { return nil }
        guard let script = script(named: name, launchedAt: Date()) else {
            preconditionFailure("台本がない: \(name)")
        }
        SciaLog.logger(category: "scenario").info("scenario start \(name, privacy: .public)")
        return ScenarioServer(script: script)
    }()

    /// 撮影モードの設定とチューニングの置き場。起動のたびに空にし、端末に残った値を使わずに既定値で撮る。
    static let defaults: UserDefaults? = {
        guard server != nil else { return nil }
        let suiteName = "net.mizle.scia.scenario"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("撮影モードのUserDefaultsを作れない")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()

    /// 台本から合図を受け取るパス（`ScenarioSignals`）。台本のイベント、録画の始めと終わり、ビューアを開く操作。
    static var signalPaths: [String] {
        let events = (server?.script.events.keys.sorted() ?? []) + ["record-start", "record-stop", "mark"]
        return events.map { "scenario/\($0)" } + ["viewer?index=0"]
    }

    /// `scia-debug://scenario/<イベント>`を処理する。`record-start`と`record-stop`は録画を始めて止め、ほかは台本のイベントとして流す。
    static func handle(_ event: String) {
        switch event {
        case "record-start": ScenarioRecorder.start()
        case "record-stop": ScenarioRecorder.stop()
        case "mark": ScenarioMarker.flash()
        default: server?.emit(event)
        }
    }

    private static func script(named name: String, launchedAt date: Date) -> ScenarioScript? {
        switch name {
        case "streaming": StreamingDemoScenario.make(launchedAt: date)
        default: nil
        }
    }
}
#endif
