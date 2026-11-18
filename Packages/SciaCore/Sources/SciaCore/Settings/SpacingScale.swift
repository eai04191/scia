/// 見た目のすき間の段。近いものほど狭くする（S1 < S2 < S3 < S4）。すき間は、文字なら字面（em枠）から測る。
/// 「投稿の見た目」の既定値と、固定した余白は、役割に合う段から取る。
public enum SpacingScale {
    /// 段の単位。
    public static let unit: Double = 4
    /// 1つの部品の中のすき間と、並んだ同類の小さい部品（サムネイル、アイコン、リアクションのボタン）のあいだ。
    public static let s1 = unit
    /// 同じまとまりの部品のあいだ（名前の行と本文、段落、行として並ぶ選択肢）と、囲みの内側の余白。
    public static let s2 = unit * 2
    /// まとまりのあいだ（本文とメディア、カード、投票、アクションバー）。
    public static let s3 = unit * 3
    /// 行の外周の余白。
    public static let s4 = unit * 4
}
