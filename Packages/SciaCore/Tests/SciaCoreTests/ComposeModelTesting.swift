@testable import SciaCore
import SciaTesting

// 投稿欄の下書きのテストでは、サムネイルを描かないので、サムネイルの型を`Never`にする。
typealias ComposeModel = SciaCore.ComposeModel<Never>
typealias ComposeMediaService = SciaCore.ComposeMediaService<Never>

extension SciaCore.ComposeModel where Thumbnail == Never {
    /// バックグラウンドの延長を頼まずに作る。延長を確かめるテストは、`backgroundTime`を渡して作る。
    convenience init(
        tasks: TaskScope,
        replyTo: Status? = nil,
        myAccountID: String,
        media: ComposeMediaService = .unavailable,
        post: @escaping (StatusDraft) async throws -> Void
    ) {
        self.init(tasks: tasks, replyTo: replyTo, myAccountID: myAccountID, media: media, backgroundTime: { _ in {} }, post: post)
    }
}
