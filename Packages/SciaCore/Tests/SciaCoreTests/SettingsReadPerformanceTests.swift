import Foundation
import Observation
import Testing
import SciaTesting
@testable import SciaCore

/// ReleaseでSCIA_BENCHMARK_SETTINGS=1を付け、設定が変わらない間の行相当の読み取りを測る。
/// 実機の描画時間は測らない。実行環境で時間が変わるため、時間を合否の条件にしない。
@Suite(.scratch, .serialized)
@MainActor
struct SettingsReadPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCIA_BENCHMARK_SETTINGS"] == "1"), arguments: [false, true])
    func rowReads(observing: Bool) throws {
        let app = AppSettings(defaults: TestScratch.defaults("SettingsReadPerformanceTests"))
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let parent = try library.create(parent: .builtIn(.compact), name: "Parent")
            let child = try library.create(parent: parent, name: "Child")
            try library.select(child, for: .account("a@example.social"))
        }
        let account = app.forAccount("a@example.social")
        func readRow() -> Double {
            var sum = account.appearance.showsTime ? 1.0 : 0.0
            for item in AppearanceCatalog.values { sum += account.value(of: item) }
            sum += account.statusActions == .standard ? 1 : 0
            sum += account.accentColor == .blue ? 1 : 0
            return sum
        }
        let expected = readRow()
        // 計測値は出力にだけ使い、待機や合否には使わない。
        // swiftlint:disable:next time_dependent_test
        let clock = ContinuousClock()
        for sample in 0..<5 {
            var checksum = 0.0
            let start = clock.now
            for _ in 0..<2000 {
                if observing {
                    checksum += withObservationTracking { readRow() } onChange: {}
                } else {
                    checksum += readRow()
                }
            }
            print("BENCH rowReads observing=\(observing) sample=\(sample) iterations=2000 elapsed=\(clock.now - start)")
            #expect(abs(checksum - expected * 2000) < 0.001)
        }
    }
}
