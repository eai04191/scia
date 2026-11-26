import os

/// 読んだフォローの関係を、アカウントのIDごとにキャッシュしておく。ログインしている間だけ持つ。
/// - 同じ相手のプロフィールを開き直したとき、読み込む前から前の関係を出し、フォローのボタンや「フォローされています」が後から現れないようにする。
/// - ユーザーのメニューの関係の項目を、キャッシュした関係でその場で組む。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
///
/// 再読み込みは、相手ごとにリクエストを送らず、`MastodonClient.multipleRelationshipsLimit`人ずつまとめて1回で読む。
/// メニューを開くたびに出る人を再読み込みしても、リクエストは1回で済む。
@MainActor
public final class RelationshipCache {
    public typealias Fetch = @Sendable ([String]) async throws -> [Relationship]

    private let fetch: Fetch
    private let limit: Int
    private var relationships: [String: Relationship] = [:]
    /// 再読み込みしている途中のIDと、それを読んでいる読み込み。同じIDを続けて求められても、二重に送らない。
    private var inFlight: [String: (load: Int, task: Task<Void, any Error>)] = [:]
    /// 再読み込みごとの番号。忘れたあとに始めた再読み込みを、前の再読み込みの終わりで外さないため。
    private var loadCount = 0
    /// IDごとに、関係を書き込んだ回数。再読み込みを頼んだあとに関係を変えたら、遅れて届いた再読み込みの応答で古い関係に戻さない。
    private var writes: [String: Int] = [:]
    private var isClosed = false
    private let logger = SciaLog.logger(category: "relationshipCache")

    /// - Parameter limit: 1回のリクエストで読む数。
    public init(limit: Int = MastodonClient.multipleRelationshipsLimit, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.limit = limit
    }

    /// キャッシュした関係。読んでいなければnil。書き込むのは、関係を変えた応答や、プロフィール画面で読んだ関係。
    public subscript(accountID: String) -> Relationship? {
        get { relationships[accountID] }
        set {
            relationships[accountID] = newValue
            writes[accountID, default: 0] += 1
        }
    }

    /// ドメインのブロックを変えたあとに、`domain`の人と、ハンドルが分からずドメインを見分けられない人の関係を忘れる。
    /// キャッシュした関係でユーザーのメニューを組むと、開いている間は再読み込みしても項目を差し替えないため、前の`domain_blocking`の項目が出る。忘れれば、再読み込みするのを待ってから出す。
    /// - Parameter acct: IDから、キャッシュしたハンドルを引く。
    public func forgetRelations(onDomain domain: String, acct: (String) -> String?) {
        // 読んでいる途中の応答も変える前の関係なので、まだキャッシュしていない相手でも忘れ、次に求められたら再読み込みする。
        for id in Set(relationships.keys).union(inFlight.keys) {
            if let acct = acct(id), !(UserHandle.domain(ofAcct: acct).map { UserHandle.mayBeSameDomain($0, domain) } ?? false) { continue }
            self[id] = nil
            inFlight[id] = nil
        }
    }

    /// `ids`の関係を、通信の目的を`purpose`と名乗って再読み込みする。再読み込みしている途中のIDは重ねて送らない。キャッシュした関係は、読み終えるまでそのまま返す。
    /// 応答に入らなかった相手（削除の予定や凍結で、Mastodonが返さない）の関係は忘れる。読めなかったら、キャッシュした関係を残してログに残す。
    public func reload(_ ids: [String], purpose: RequestPurpose) {
        guard !isClosed else { return }
        var seen = Set<String>()
        let missing = ids.filter { seen.insert($0).inserted && inFlight[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: limit) {
            let chunk = Array(missing[start..<min(start + limit, missing.count)])
            let writesAtStart = chunk.map { writes[$0, default: 0] }
            loadCount += 1
            let load = loadCount
            let task = Task {
                defer {
                    for id in chunk where inFlight[id]?.load == load {
                        inFlight[id] = nil
                    }
                }
                do {
                    let loaded = Dictionary(try await RequestPurpose.$current.withValue(purpose) { try await fetch(chunk) }.map { ($0.id, $0) }) { first, _ in first }
                    for (index, id) in chunk.enumerated() where writes[id, default: 0] == writesAtStart[index] {
                        relationships[id] = loaded[id]
                    }
                } catch {
                    logger.error("relationships load failed count=\(chunk.count, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                    throw error
                }
            }
            for id in chunk {
                inFlight[id] = (load, task)
            }
        }
    }

    /// 走っている再読み込みを止め、以後は読まない。ログアウトやアカウントの切り替えのあとに、前のアカウントのトークンで通信し続けないため。
    public func close() {
        isClosed = true
        for task in Set(inFlight.values.map(\.task)) {
            task.cancel()
        }
    }

    /// 相手との関係。再読み込みしている途中ならそれを待ち、キャッシュしていなければ読む。サーバーが返さなかった（見つからない）ならnil。
    /// 再読み込みに失敗したら、キャッシュした関係があっても投げる。
    public func relationship(_ id: String) async throws -> Relationship? {
        while true {
            if inFlight[id] == nil, relationships[id] == nil {
                // 待っている呼び出し側が名乗った目的で読む。
                reload([id], purpose: try RequestPurpose.declared())
            }
            let writesBefore = writes[id, default: 0]
            if let task = inFlight[id]?.task {
                try await task.value
            }
            // 待っている間に忘れたら、届いた応答は忘れる前に読んだものなので、再読み込みする。
            guard relationships[id] == nil, writes[id, default: 0] != writesBefore else { return relationships[id] }
        }
    }
}
