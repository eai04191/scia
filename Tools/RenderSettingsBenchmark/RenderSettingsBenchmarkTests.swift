import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@Suite(.scratch, .failureState, .serialized)
@MainActor
struct RenderSettingsBenchmarkTests {
    private func settings() throws -> AppSettings {
        let app = AppSettings.isolated()
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let parent = try library.create(parent: .builtIn(.compact), name: "Parent")
            let child = try library.create(parent: parent, name: "Child")
            try library.select(child, for: .account("bench@example.social"))
        }
        return app.forAccount("bench@example.social")
    }

    private func posts() -> [Status] {
        (0..<24).map { index in
            Status(id: "\(index)", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                   account: Account(id: "author", username: "author", acct: "author", displayName: "表示名", avatar: nil),
                   content: "<p>投稿\(index)の本文です。<a href=\"https://example.com/\(index)\">リンク</a>と日本語・Englishを含みます。</p>",
                   spoilerText: index.isMultiple(of: 3) ? "注意書き" : "", language: "ja", url: nil)
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    @Test(arguments: [false, true]) func measureRows(layout: Bool) throws {
        let settings = try settings()
        let cache = PostRenderSettings(settings: settings)
        let initialValues = cache.read()
        let posts = posts()
        let tuning = TuningStore(defaults: nil)
        let base = UIListContentConfiguration.cell()
        // 性能の出力にだけ使い、時間を合否に使わない。
        // swiftlint:disable:next time_dependent_test
        let clock = ContinuousClock()
        var checksum = 0
        let builder = PostContentBuilder(tuning: tuning, renderSettings: cache, emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
        let view = PostContentView(configuration: builder.configuration(for: posts[0], base: base))
        func run(count: Int) {
            for index in 0..<count {
                autoreleasepool {
                    // 実際のタイムラインと同じくbuilderを行ごとに作り、キャッシュの参照も計測に含める。
                    let configuration = PostContentBuilder(tuning: tuning, renderSettings: cache, emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
                        .configuration(for: posts[index % posts.count], base: base)
                    checksum += configuration.body.length
                    if layout {
                        view.configuration = configuration
                        let size = view.systemLayoutSizeFitting(CGSize(width: 390, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                        view.frame = CGRect(origin: .zero, size: size)
                        view.layoutIfNeeded()
                        checksum += Int(size.height)
                    }
                }
            }
        }
        run(count: 100)
        for sample in 0..<9 {
            let start = clock.now
            run(count: 500)
            print("RENDER_BENCH layout=\(layout) sample=\(sample) rows=500 ms=\(milliseconds(clock.now - start))")
        }
        #expect(checksum > 0)
        #expect(cache.read() === initialValues)
    }
}
