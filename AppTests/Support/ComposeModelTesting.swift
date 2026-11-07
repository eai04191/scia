import Foundation
import SciaCore
import UIKit

extension ComposeModel where Thumbnail == UIImage {
    /// 送った結果を使わないテストのために、送った下書きだけを受け取って作る。結果は送った下書きに合う種類の決まった値にする。
    convenience init(
        tasks: TaskScope,
        myAccountID: String,
        media: ComposeMediaService<UIImage> = .unavailable,
        backgroundTime: @escaping @MainActor (String) -> @MainActor () -> Void,
        post: @escaping (StatusDraft) async throws -> Void
    ) {
        self.init(tasks: tasks, myAccountID: myAccountID, media: media, backgroundTime: backgroundTime) { draft in
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
