import Foundation
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
        redraft: ComposeRedraftService = .unavailable,
        post: @escaping (StatusDraft) async throws -> Void
    ) {
        self.init(tasks: tasks, replyTo: replyTo, myAccountID: myAccountID, media: media, redraft: redraft, backgroundTime: { _ in {} }, post: post)
    }

    /// 送った結果を使わないテストのために、送った下書きだけを受け取って作る。結果は`SubmittedDraft.stub(for:)`にする。
    convenience init(
        tasks: TaskScope,
        replyTo: Status? = nil,
        myAccountID: String,
        media: ComposeMediaService = .unavailable,
        redraft: ComposeRedraftService = .unavailable,
        backgroundTime: @escaping @MainActor (String) -> @MainActor () -> Void,
        post: @escaping (StatusDraft) async throws -> Void
    ) {
        self.init(tasks: tasks, replyTo: replyTo, myAccountID: myAccountID, media: media, redraft: redraft, backgroundTime: backgroundTime) { draft in
            try await post(draft)
            return .stub(for: draft)
        }
    }
}

extension ComposeAccount where Thumbnail == Never {
    /// 送った結果を使わないテストのために、送った下書きだけを受け取って作る。結果は`SubmittedDraft.stub(for:)`にする。
    init(id: String, myAccountID: String, media: ComposeMediaService, redraft: ComposeRedraftService = .unavailable, onRedraftDeleted: @escaping (Status.ID) -> Void = { _ in }, post: @escaping (StatusDraft) async throws -> Void) {
        self.init(id: id, myAccountID: myAccountID, media: media, redraft: redraft, onRedraftDeleted: onRedraftDeleted) { draft in
            try await post(draft)
            return .stub(for: draft)
        }
    }
}

extension SubmittedDraft {
    /// 送った下書きに合う種類の結果。中身はテストで使わない決まった値にする。
    static func stub(for draft: StatusDraft) -> SubmittedDraft {
        if draft.editing != nil {
            return .edited(stubStatus)
        }
        if let scheduledAt = draft.scheduledAt {
            return .scheduled(ScheduledStatus(id: "stub", scheduledAt: scheduledAt, params: ScheduledStatus.Params(text: draft.text)))
        }
        return .posted(stubStatus)
    }

    private static var stubStatus: Status {
        Status(
            id: "stub",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "",
            url: nil,
            visibility: .public
        )
    }
}
