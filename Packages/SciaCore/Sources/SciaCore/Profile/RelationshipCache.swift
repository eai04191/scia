/// 読んだフォローの関係を、アカウントのIDごとに覚えておく。ログインしている間だけ持つ。
/// 同じ相手のプロフィールを開き直したとき、読み込む前から前の関係を出し、フォローのボタンや「フォローされています」が後から現れないようにする。
@MainActor
public final class RelationshipCache {
    private var relationships: [String: Relationship] = [:]

    public init() {}

    public subscript(accountID: String) -> Relationship? {
        get { relationships[accountID] }
        set { relationships[accountID] = newValue }
    }
}
