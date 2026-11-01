public import Foundation

/// APIの応答の本文を、人が読むための文字にする。投稿のメニューの「APIの応答」で出す。
public enum APIResponseText {
    /// 字下げしたJSON。サーバーが返した並びは`JSONSerialization`で読むと失われるため、キーは名前の順に並べ、読むたびに同じ並びにする。
    /// JSONとして読めなければ投げる。
    public static func formatted(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: formatted, as: UTF8.self)
    }
}
