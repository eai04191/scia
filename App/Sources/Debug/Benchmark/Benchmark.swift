import UIKit

/// デバッグメニューの「ベンチマーク」に並べる計測。実機で走らせ、結果のテキストをコピーして貼ってもらうため、Releaseでも使える。
/// 足すときは、このフォルダーに1つのファイルで`extension Benchmark { static let ... }`を書き、`all`に1行足す。
@MainActor
struct Benchmark {
    /// `scia-debug://benchmark/<id>`の名前。
    let id: String
    let title: String
    /// 計測の本体。`stage`に置いたビューで測り、結果の行を返す。端末とビルドの情報は画面が先頭に足す。
    let run: @MainActor (_ stage: UIView) async throws -> [String]

    static let all: [Benchmark] = [
        .springFrameRate,
    ]
}
