/// 投稿IDの新旧を比べる。
///
/// MastodonのIDは時刻から作る数字の文字列で、桁数が増えることがあるため、桁数、文字列の順に比べる。
/// GoToSocialのULIDは桁数が一定で、文字列の順がそのまま時刻の順になるため、同じ比べ方で扱える。
public enum StatusID {
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        lhs.count != rhs.count ? lhs.count > rhs.count : lhs > rhs
    }
}
