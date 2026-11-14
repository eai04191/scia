/// 投稿IDの新旧を比べる。
///
/// MastodonのIDは時刻から作る数字の文字列で、桁数が増えることがあるため、桁数、文字列の順に比べる。
/// GoToSocialのULIDは桁数が一定で、文字列の順がそのまま時刻の順になるため、同じ比べ方で扱える。
public enum StatusID {
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        lhs.count != rhs.count ? lhs.count > rhs.count : lhs > rhs
    }

    /// `id`のすぐ上の値。`max_id`は端の投稿を含めずに返すので、`id`の投稿そのものから古い方を読みたいときに、`max_id`として使う。投稿を指すIDではない。
    /// Mastodonのホームは`max_id`をRedisのスコア（倍精度）で比べるため（app/models/feed.rb）、スコアでも`id`より上になる値にする。
    /// 今のIDは倍精度で表せる整数の範囲を超えていて、1を足しただけでは同じスコアに丸まり、`id`の投稿まで除かれるため。
    /// スコアが同じになる`id`のすぐ上の投稿も一緒に返るが、読み込み済みの投稿と重ねて持つことはない。
    /// Mastodonの10進の数字のIDでなければnil。
    public static func justAbove(_ id: String) -> String? {
        guard id.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(id), value < UInt64.max else { return nil }
        guard let aboveScore = UInt64(exactly: Double(value).nextUp.rounded(.up)) else { return nil }
        return String(max(value + 1, aboveScore))
    }
}
