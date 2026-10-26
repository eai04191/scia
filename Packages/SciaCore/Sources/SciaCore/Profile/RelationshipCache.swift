import os

/// 読んだフォローの関係を、アカウントのIDごとに覚えておく。ログインしている間だけ持つ。
/// - 同じ相手のプロフィールを開き直したとき、読み込む前から前の関係を出し、フォローのボタンや「フォローされています」が後から現れないようにする。
/// - ユーザーのメニューの関係の項目を、覚えている関係でその場で組む。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
///
/// 読み直しは、相手ごとにリクエストを送らず、`MastodonClient.multipleRelationshipsLimit`人ずつまとめて1回で読む。
/// メニューを開くたびに出る人を読み直しても、リクエストは1回で済む。
@MainActor
public final class RelationshipCache {
    public typealias Fetch = @Sendable ([String]) async throws -> [Relationship]

    private let fetch: Fetch
    private let limit: Int
    private var relationships: [String: Relationship] = [:]
    /// 読み直している途中のIDと、それを読んでいる読み込み。同じIDを続けて求められても、二重に送らない。
    private var inFlight: [String: Task<Void, any Error>] = [:]
    /// IDごとに、関係を書き込んだ回数。読み直しを頼んだあとに関係を変えたら、遅れて届いた読み直しの応答で古い関係に戻さない。
    private var writes: [String: Int] = [:]
    private let logger = SciaLog.logger(category: "relationshipCache")

    /// - Parameter limit: 1回のリクエストで読む数。
    public init(limit: Int = MastodonClient.multipleRelationshipsLimit, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.limit = limit
    }

    /// 覚えている関係。読んでいなければnil。書き込むのは、関係を変えた応答や、プロフィール画面で読んだ関係。
    public subscript(accountID: String) -> Relationship? {
        get { relationships[accountID] }
        set {
            relationships[accountID] = newValue
            writes[accountID, default: 0] += 1
        }
    }

    /// `ids`の関係を読み直す。読み直している途中のIDは重ねて送らない。覚えている関係は、読み終えるまでそのまま返す。
    /// 応答に入らなかった相手（削除の予定や凍結で、Mastodonが返さない）の関係は忘れる。読めなかったら、覚えている関係を残してログに残す。
    public func reload(_ ids: [String]) {
        var seen = Set<String>()
        let missing = ids.filter { seen.insert($0).inserted && inFlight[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: limit) {
            let chunk = Array(missing[start..<min(start + limit, missing.count)])
            let writesAtStart = chunk.map { writes[$0, default: 0] }
            let task = Task {
                defer {
                    for id in chunk {
                        inFlight[id] = nil
                    }
                }
                do {
                    let loaded = Dictionary(try await fetch(chunk).map { ($0.id, $0) }) { first, _ in first }
                    for (index, id) in chunk.enumerated() where writes[id, default: 0] == writesAtStart[index] {
                        relationships[id] = loaded[id]
                    }
                } catch {
                    logger.error("relationships load failed count=\(chunk.count, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                    throw error
                }
            }
            for id in chunk {
                inFlight[id] = task
            }
        }
    }

    /// 相手との関係。読み直している途中ならそれを待ち、覚えていなければ読む。サーバーが返さなかった（見つからない）ならnil。
    /// 読み直しに失敗したら、覚えている関係があっても投げる。
    public func relationship(_ id: String) async throws -> Relationship? {
        if inFlight[id] == nil, relationships[id] == nil {
            reload([id])
        }
        if let task = inFlight[id] {
            try await task.value
        }
        return relationships[id]
    }
}
