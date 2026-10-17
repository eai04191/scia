/// 注意書き（CW）のある投稿の本文を開いているか。
///
/// 開閉は元の投稿のIDで覚え、同じ投稿のブーストや通知の行もそろえる。覚えるのはアプリを起動している間だけ。
/// 開閉を選んでいない投稿は、サーバーの設定（`reading:expand:spoilers`）に従う。
public struct SpoilerExpansion: Sendable, Equatable {
    /// 開閉を選んでいない投稿を、最初から開いておくか。
    public var expandsByDefault: Bool
    private var choices: [Status.ID: Bool] = [:]

    public init(expandsByDefault: Bool = false) {
        self.expandsByDefault = expandsByDefault
    }

    /// 本文を畳んでいるか。注意書きのない投稿は畳まない。ブーストなら元の投稿で決める。
    public func isCollapsed(_ status: Status) -> Bool {
        let shown = status.displayed
        guard !shown.spoilerText.isEmpty else { return false }
        return !(choices[shown.id] ?? expandsByDefault)
    }

    /// 開いていれば閉じ、閉じていれば開く。
    public mutating func toggle(_ status: Status) {
        let shown = status.displayed
        choices[shown.id] = isCollapsed(shown)
    }
}
