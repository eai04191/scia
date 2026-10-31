public import Foundation

/// まとめて共有するときに、共有のシートへ渡すもの。決まりはdocs/batch-actions.mdの「共有」にある。
public struct BatchSharePayload: Sendable, Equatable {
    /// 選んだ順に、各投稿の本文を空行でつないだ文章。本文のある投稿がなければnil。
    public let text: String?
    /// 選んだ順に、投稿ごとに添付ファイルの順で並べたメディアの元のファイル。サーバーが処理中でURLのないものは除く。
    public let media: [MediaTransfers.Target]

    /// - Parameter statuses: 選んだ順の投稿。同じ投稿（ブーストなら元の投稿）は、先に選んだほうの順番で1度だけ渡す。
    @MainActor
    public init(statuses: [Status]) {
        let shown = BatchTargets.unique(statuses).map(\.displayed)
        let texts = shown.compactMap(StatusMenuTree.plainText(of:))
        text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        media = shown.flatMap { status in
            status.mediaAttachments.compactMap { attachment in
                attachment.url.map { MediaTransfers.Target(url: $0, kind: attachment.type, subject: OperationStatus.Subject(status)) }
            }
        }
    }
}

/// まとめて共有するメディアを、選んだ順に1つずつ落とす。
@MainActor
public enum BatchShareDownload {
    /// `targets`のファイルを順に用意し、同じ順で返す。進み具合は、落とし終えた数と、落としている途中のものの割合を足して、全体の数で割った0から1で渡す。
    /// 1つでも落とせなければ、そこで投げる。呼び出し側のタスクを取り消したら、通信も止める。
    public static func fetchAll(_ targets: [MediaTransfers.Target], fetch: MediaTransfers.Fetch, onProgress: @escaping @MainActor (_ completed: Int, _ fraction: Double) -> Void) async throws -> [URL] {
        var files: [URL] = []
        let total = Double(max(targets.count, 1))
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let file = try await fetch(target.url) { fraction in
                onProgress(index, (Double(index) + min(max(fraction, 0), 1)) / total)
            }
            files.append(file)
            onProgress(index + 1, Double(index + 1) / total)
        }
        return files
    }
}
