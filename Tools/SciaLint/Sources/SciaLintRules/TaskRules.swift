import SwiftSyntax

extension Rule {
    // セッションの持ち物（各タイムライン、開いた画面、投稿欄）で始める処理は、持ち主（TaskScope）を通す。持ち主を通さないTaskは、ログアウト、アカウントの切り替え、
    // 窓を閉じたときに止まらず、前のアカウントのトークンで送り続けたり、終わった処理が溜まり続けたりしていた。止める処理を手で並べて保たずに済むよう、ここで止める。
    // 変化の知らせを受けてメインアクターへ戻るだけの乗り換え（`Task { @MainActor`）は、通信を持たないので対象外にする
    static let sessionTaskOutsideScope = Rule(
        id: "session_task_outside_scope",
        message: "セッションの持ち物で始める処理は、持ち主（TaskScope）のrunで始める。メインアクターへ戻るだけなら、アプリでは`Task(.withoutRequests) {`、SciaCoreでは`Task { @MainActor`と書く",
        appliesTo: { sessionOwnedFiles.contains($0) },
        find: { tree in
            tree.taskStarts
                .filter { start in
                    guard case .task = start.kind else { return false }
                    return !start.isWithoutRequests && !start.hopsToMainActor
                }
                .map(\.call.positionAfterSkippingLeadingTrivia)
        }
    )

    // 持ち主（TaskScope）を通らずに始める処理は、始めるところで通信の目的を名乗る（docs/network.md）。名乗らない通信は通信の入口が送らずに失敗させるが、
    // task-localの値はコンパイラが確かめられないため、名乗り忘れは実行時まで分からない。始める書き方をここで縛り、`Task(.action) {`のように目的を名乗るか、
    // 通信しない処理は`Task(.withoutRequests) {`と書かせる。SwiftUIの`.task`も同じ（`.task(.action) {`、`.task(.withoutRequests, id:) {`）。
    // SciaCoreのTaskは、名乗った処理の中で目的を引き継ぐために作るものが多いので対象外にし、同期の入口から始めるものは引数で目的を受け取る
    static let taskWithoutRequestPurpose = Rule(
        id: "task_without_request_purpose",
        message: "処理を始めるところで通信の目的を名乗る。`Task(.action) {`、`Task(.display) {`のように書き、通信しない処理は`Task(.withoutRequests) {`（すぐ始めるなら`Task.immediate(.withoutRequests) {`）と書く。SwiftUIでは`.task(.action) {`と書く。`Task.detached`は使わない",
        appliesTo: { $0.hasPrefix("App/Sources/") && !$0.hasPrefix("App/Sources/Debug/") },
        find: { tree in
            let withoutPurpose = tree.taskStarts
                .filter { start in
                    switch start.kind {
                    case .task(nil), .task("immediate"), .modifier:
                        !start.namesPurpose
                    case .task:
                        // `Task.detached`と`Task.init`は、下で関数に触れたところで止める
                        false
                    }
                }
                .map(\.call.positionAfterSkippingLeadingTrivia)
            return (withoutPurpose + tree.unnamedTaskFunctions.map(\.positionAfterSkippingLeadingTrivia)).sorted()
        }
    )

    private static let sessionOwnedFiles: Set = [
        "App/Sources/SessionController.swift",
        "App/Sources/Timeline/FeedTimelineController.swift",
        "App/Sources/Timeline/NotificationsController.swift",
        "App/Sources/Timeline/SavedStatusesController.swift",
        "App/Sources/Profile/ProfileController.swift",
        "App/Sources/Profile/AccountListController.swift",
        "App/Sources/Thread/ThreadController.swift",
        "App/Sources/Compose/ComposeModel.swift",
        "App/Sources/Compose/InlineComposeController.swift",
        "Packages/SciaCore/Sources/SciaCore/Timeline/FeedTimelineModel.swift",
        "Packages/SciaCore/Sources/SciaCore/Timeline/NotificationsModel.swift",
        "Packages/SciaCore/Sources/SciaCore/Timeline/SavedStatusesModel.swift",
        "Packages/SciaCore/Sources/SciaCore/Timeline/ScheduledStatusesModel.swift",
        "Packages/SciaCore/Sources/SciaCore/Thread/ThreadModel.swift",
    ]
}
