import Foundation
import SciaCore
import os

/// フレームが落ちたスクロールで、落ちたフレームに使った処理をログに残し、起動をまたいで1つのファイルに足し上げる。
/// ログは違和感レポートでそのスクロールを読むため、ファイルはふだん使っている間に重かった処理を、まとめて選ぶためのもの。
enum FrameWorkLog {
    private static let logger = SciaLog.logger(category: "frameWork")

    /// ファイルアプリと`xcrun simctl get_app_container`から取り出せるよう、Documentsに置く。
    static let store = FrameWorkStore(file: URL.documentsDirectory.appending(path: "FrameWork.json"))

    /// 書き込みを1つずつ行う。続けて足したときに、読んでから書くまでの間に別の書き込みが入って、片方が消えないようにするため。
    private static let writer = Writer()

    static func record(_ work: FrameWorkTally, screen: String) {
        guard !work.isEmpty else { return }
        logger.notice("scroll hitch work screen=\(screen, privacy: .public) \(work.logLine, privacy: .public)")
        Task { await writer.add(work) }
    }

    private actor Writer {
        func add(_ work: FrameWorkTally) {
            do {
                try FrameWorkLog.store.add(work)
            } catch {
                FrameWorkLog.logger.error("frame work save failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }
}
