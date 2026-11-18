/// 見た目のすき間の段。近いものほど狭くする（S1 < S2 < S3 < S4）。すき間は、文字なら字面（em枠）から測る。
/// 「投稿の見た目」と「通知の見た目」のすき間の既定値と、固定した余白は、役割に合う段から取る。組み込みのプリセットは、段の単位だけを変える。
public enum SpacingScale {
    /// 段の単位。
    public static let unit: Double = 4

    public enum Level: Int, CaseIterable, Sendable, Hashable {
        /// 1つの部品の中のすき間と、並んだ同類の小さい部品（サムネイル、アイコン、リアクションのボタン）のあいだ。
        case s1 = 1
        /// 同じまとまりの部品のあいだ（名前の行と本文、段落、行として並ぶ選択肢）と、囲みの内側の余白。
        case s2
        /// まとまりのあいだ（本文とメディア、カード、投票、アクションバー）。
        case s3
        /// 行の外周の余白。
        case s4

        /// 単位が`unit`のときの長さ。
        public func value(unit: Double = SpacingScale.unit) -> Double {
            unit * Double(rawValue)
        }
    }

    public static let s1 = Level.s1.value()
    public static let s2 = Level.s2.value()
    public static let s3 = Level.s3.value()
    public static let s4 = Level.s4.value()
}
