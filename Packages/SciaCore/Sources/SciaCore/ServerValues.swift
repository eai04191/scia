import Foundation

/// サーバーが返す件数（お気に入りの数、フォロワーの数、票の数、通知のまとまりの人数など）と、大きさ（画素数やバイト数）。
/// サーバーは範囲を確かめずに返すことがあり、ほかのサーバーから届いた値をそのまま渡すこともある。Swiftの整数は、あふれると止まって落ちる。
/// 読むところで`0...upperBound`に収め、そのあとの計算（1を足す、いくつかを足し合わせる）であふれないようにする。
public enum ServerCount {
    /// 倍精度の浮動小数点数で正確に表せる最大の整数。MastodonのwebはJSONの数をこの精度で扱うため、これより大きい数は表示できない。
    /// これに収めておけば、2倍しても、`Double`に直しても、桁あふれも誤差も出ない。
    public static let upperBound = 1 << 53

    /// 範囲の外の数を、近いほうの端にする。
    public static func clamped(_ value: Int) -> Int {
        min(max(value, 0), upperBound)
    }

    /// 足し合わせた数。上限を超えたら上限にする。足す数の個数もサーバーが決めるため、1つずつ収めながら足す。
    public static func sum(_ values: some Sequence<Int>) -> Int {
        values.reduce(0) { min($0 + clamped($1), upperBound) }
    }
}

/// サーバーが決める上限（文字数、添付の数、容量、投票の期限など）。1以上の値だけを受け付け、0以下や整数として読めない値はnilにする。
/// 0以下の上限は、どの投稿も送れなくなるか、引き算で負の数を作るだけで、意味のある設定ではないため、返さなかったものとして既定値で補う。
/// 大きすぎる値は`ServerCount.upperBound`に収め、そこから引いたり掛けたりしてもあふれないようにする。
struct ServerLimit: Decodable {
    let value: Int?

    init(from decoder: any Decoder) {
        let value = try? decoder.singleValueContainer().decode(Int.self)
        self.value = value.flatMap { $0 > 0 ? min($0, ServerCount.upperBound) : nil }
    }
}

/// サーバーが返したURLの使い道。使い道ごとに受け付けるスキームを決め、読むところで確かめる。
enum ServerURLKind {
    /// 読み込んで表示する画像やメディア。http、https、data:を受け付ける。
    /// data:は中身をURLの中に持ち、端末のファイルにもほかのアプリにも触れないため、httpsより危なくない。
    /// デバッグのシナリオは、画像をdata:のURLにしてサーバーの応答と同じ形のJSONで渡す。
    /// file:を受け付けると、サーバーが端末の中のファイルを読ませたり、再生させたり、共有させたりできてしまう。
    case media
    /// 押して開く先（投稿、アカウント、メンション、ハッシュタグ、カードのリンク先）。httpとhttpsだけを受け付ける。
    /// ほかのスキームは外のアプリに渡すことになり、サーバーが選んだアプリ（電話、メッセージなど）を起動できてしまう。
    /// 本文のリンクは、Mastodonがgeminiやmagnetなども通す決まりで、書いた人が見える形で置いたものなので、ここでは扱わない。
    case destination

    func accepts(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host()?.isEmpty == false
        case "data": self == .media
        default: false
        }
    }

    /// 受け付けるなら`url`、受け付けなければnil。
    func accepting(_ url: URL) -> URL? {
        accepts(url) ? url : nil
    }
}

extension KeyedDecodingContainer {
    /// 件数を読む。範囲の外の値は`ServerCount`の範囲に収める。整数として読めなければ投げる。
    func decodeCount(forKey key: Key) throws -> Int {
        ServerCount.clamped(try decode(Int.self, forKey: key))
    }

    /// 件数を読む。項目がない、またはnullならnil。
    func decodeCountIfPresent(forKey key: Key) throws -> Int? {
        try decodeIfPresent(Int.self, forKey: key).map(ServerCount.clamped)
    }

    /// 表示や読み込みのためのURLを読む。項目がない、null、空、URLとして読めない値、`kind`で受け付けないスキームはnilにする。
    func decodeURL(_ kind: ServerURLKind, forKey key: Key) -> URL? {
        guard let string = try? decodeIfPresent(String.self, forKey: key), !string.isEmpty, let url = URL(string: string), kind.accepts(url) else { return nil }
        return url
    }

    /// 欠かせないURLを読む。なければ、または`kind`で受け付けなければ投げ、それを含むものごと読めないものとする。
    func decodeRequiredURL(_ kind: ServerURLKind, forKey key: Key) throws -> URL {
        let url = try decode(URL.self, forKey: key)
        guard kind.accepts(url) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "受け付けないスキームのURLです")
        }
        return url
    }
}
