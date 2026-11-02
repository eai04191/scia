public import CoreGraphics

/// 投稿欄の開閉で、本文の文字を、書いていないときのカプセルの1行（A）から書いているときの入力欄（B）へ動かす計画。
///
/// 文字は、Bの1行ずつに切ったかたまりで動かす。Aは1行なので、Bの1行に入る文字はAでも並びが同じで、かたまりのまま平行に動かせる。
/// 両方ではっきり見えている文字のかたまりは、Aの位置からBの位置へ動かす。Aではっきり見えていない（カプセルの行末のぼかしの中か、その先にある）文字だけのBの行は、
/// Aの位置から動かすと、前の行の上を通って横切るので、Bの位置で浮かび上がらせる。ぼかしの中の文字は、カプセルの行と一緒にその場で薄くする。
/// 返信の宛先のようにBにしかない文字も、Bの位置で浮かび上がらせる。
/// カプセルの行末のぼかしにかかっていて動かさない文字（行末）は、その前の動かすかたまりと一緒に動かしながら薄くする。その場に残して薄くすると、
/// 動いていく行から離れて、欠けた文字が浮いて見えたため。
/// Aにしかない文字（返信の宛先だけを書いたときの、カプセルの「いまどうしてる？」）は、動かす文字がなければ、Bにしかない文字と同じ場所に出入りする。
/// 両方を同時に薄くしたり濃くしたりすると重なって見えるので、Aにしかない文字を先に消し切ってから、Bにしかない文字を浮かび上がらせる。
///
/// 行の中の文字は左から右へ並ぶ前提で、境目の位置（`Line.boundaries`）は文字の順に右へ進むとしている。右から左へ書く文字（ヘブライ語、アラビア語）を含む本文では、
/// この前提が崩れる。右から左の文字だけの本文では、カプセルの本物を隠す範囲がほぼ空になり、本物と動くかたまりが重なって見える。英字と混ざった本文では、
/// かたまりを本文から切り出して描くと文字の並びが本文の中と変わり、動き始めと着地で文字が跳ぶ（証明のテストでは約36pt）。
/// 直すには、計画と描画の両方を、文字の並ぶ向きがそろった区切りごとに組み直す必要があるので、今回は対応しない（docs/roadmap.mdに載せている）。
public struct TextMorphPlan: Equatable, Sendable {
    /// 動かすかたまりと、その場で出し入れするかたまりを見分ける。開閉を途中で逆にしたときに、同じかたまりを向かい直させるため。
    public struct Key: Hashable, Sendable {
        public let content: TextMorphContent
        public let range: Range<Int>
    }

    /// AからBへ動かすかたまり。`range`は`content`の中の位置（UTF-16）。
    public struct Flight: Equatable, Sendable {
        public let key: Key
        /// かたまりの頭の文字の、ベースラインの左の点。
        public let originInA: CGPoint
        public let originInB: CGPoint
    }

    /// Bの位置で浮かび上がらせる（閉じるときは薄くする）かたまり。
    public struct Stay: Equatable, Sendable {
        public let key: Key
        public let originInB: CGPoint
    }

    /// Aの行末で、前の動かすかたまりと一緒に動かしながら薄くするかたまり。
    public struct Tail: Equatable, Sendable {
        public let key: Key
        public let originInA: CGPoint
        /// 一緒に動かすかたまり。
        public let follows: Key
    }

    /// Aにしかない、その場で出し入れするかたまり。動かす文字がないときだけ作る。
    public struct Departure: Equatable, Sendable {
        public let key: Key
        public let originInA: CGPoint
    }

    public let flights: [Flight]
    public let stays: [Stay]
    public let tails: [Tail]
    public let departures: [Departure]

    /// Aで隠す範囲。動かす文字、行末、Aにしかない文字はかたまりが描くので、カプセルの本物では描かない。
    public var concealedInA: [Key] { flights.map(\.key) + tails.map(\.key) + departures.map(\.key) }
    /// Bで隠す範囲。Bの文字は、動かすものも出し入れするものも、かたまりが描く。
    public var concealedInB: [Key] { flights.map(\.key) + stays.map(\.key) }

    public init(a: TextMorphScene, b: TextMorphScene) {
        var flights: [Flight] = []
        var stays: [Stay] = []
        for line in b.lines {
            let shared = a.lines.lazy.compactMap { aLine -> (TextMorphScene.Line, Range<Int>)? in
                guard aLine.content == line.content else { return nil }
                let overlap = line.range.clamped(to: aLine.range)
                return overlap.isEmpty ? nil : (aLine, overlap)
            }.first
            if let (aLine, overlap) = shared, a.showsAnyCharacter(of: overlap, on: aLine) {
                flights.append(Flight(key: Key(content: line.content, range: overlap), originInA: aLine.origin(of: overlap.lowerBound), originInB: line.origin(of: overlap.lowerBound)))
                guard b.shows(line) else { continue }
                // 同じ行のうちAにない部分（返信の宛先など）は、Bの位置で浮かび上がらせる。
                for rest in [line.range.lowerBound ..< overlap.lowerBound, overlap.upperBound ..< line.range.upperBound] where !rest.isEmpty {
                    stays.append(Stay(key: Key(content: line.content, range: rest), originInB: line.origin(of: rest.lowerBound)))
                }
            } else if b.shows(line), !line.range.isEmpty {
                stays.append(Stay(key: Key(content: line.content, range: line.range), originInB: line.origin(of: line.range.lowerBound)))
            }
        }
        self.flights = flights
        let tails = a.lines.compactMap { line -> Tail? in
            // 行の中で最後に動かす文字の後ろから、少しでも見えている文字まで。
            guard let last = flights.filter({ $0.key.content == line.content && line.range.contains($0.key.range.lowerBound) }).max(by: { $0.key.range.upperBound < $1.key.range.upperBound }) else { return nil }
            let end = line.range.first { a.window.maxX <= line.origin.x + line.boundaries[$0 - line.range.lowerBound] } ?? line.range.upperBound
            guard last.key.range.upperBound < end else { return nil }
            return Tail(key: Key(content: line.content, range: last.key.range.upperBound ..< end), originInA: line.origin(of: last.key.range.upperBound), follows: last.key)
        }
        self.tails = tails
        // 行末と同じ文字は、Bでは行末と入れ替わりに出入りさせるので、別のかたまりに分ける。行のほかの文字まで待たせないため。
        self.stays = stays.flatMap { stay -> [Stay] in
            guard let tail = tails.first(where: { $0.key.content == stay.key.content && $0.key.range.overlaps(stay.key.range) }),
                  let line = b.lines.first(where: { $0.content == stay.key.content && $0.range.contains(stay.key.range.lowerBound) }) else { return [stay] }
            let overlap = stay.key.range.clamped(to: tail.key.range)
            return [stay.key.range.lowerBound ..< overlap.lowerBound, overlap, overlap.upperBound ..< stay.key.range.upperBound]
                .filter { !$0.isEmpty }
                .map { Stay(key: Key(content: stay.key.content, range: $0), originInB: line.origin(of: $0.lowerBound)) }
        }
        departures = flights.isEmpty
            ? a.lines.filter { line in !line.range.isEmpty && !b.lines.contains { $0.content == line.content } }.map { Departure(key: Key(content: $0.content, range: $0.range), originInA: $0.origin) }
            : []
    }
}

/// 文字の出どころ。本文は両方の場面で同じ位置で数える。「いまどうしてる？」は本文と別に数える。
public enum TextMorphContent: Hashable, Sendable {
    case body
    case placeholder
}

/// 開閉のどちらかの端での、文字の配置。座標は両方の端で同じ入れ物の中のもの。
public struct TextMorphScene: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let content: TextMorphContent
        /// この行の文字の範囲（UTF-16）。
        public let range: Range<Int>
        /// 行の頭の文字の、ベースラインの左の点。
        public let origin: CGPoint
        /// 行の頭から数えた、文字の境目ごとの横の位置。`range`の文字の数より1つ多く、最後は行の文字の終わり。
        public let boundaries: [CGFloat]
        /// ベースラインから上と下の、行の高さ。
        public let ascent: CGFloat
        public let descent: CGFloat

        public init(content: TextMorphContent, range: Range<Int>, origin: CGPoint, boundaries: [CGFloat], ascent: CGFloat, descent: CGFloat) {
            precondition(boundaries.count == range.count + 1, "文字の境目は文字の数より1つ多い")
            self.content = content
            self.range = range
            self.origin = origin
            self.boundaries = boundaries
            self.ascent = ascent
            self.descent = descent
        }

        public func origin(of index: Int) -> CGPoint {
            CGPoint(x: origin.x + boundaries[index - range.lowerBound], y: origin.y)
        }

        var verticalRange: ClosedRange<CGFloat> { (origin.y - ascent) ... (origin.y + descent) }
    }

    public let lines: [Line]
    /// 文字が見える範囲。外側の端に向けて、`fade`の幅で透明へ薄くする。
    public let window: CGRect
    public let fade: TextMorphFade

    public init(lines: [Line], window: CGRect, fade: TextMorphFade) {
        self.lines = lines
        self.window = window
        self.fade = fade
    }

    /// 行のどこかが見える範囲にかかっているか。
    func shows(_ line: Line) -> Bool {
        line.verticalRange.overlaps(window.minY ... window.maxY)
            && line.origin.x + (line.boundaries.first ?? 0) < window.maxX
            && line.origin.x + (line.boundaries.last ?? 0) > window.minX
    }

    /// `range`のどれかの文字が、薄くせずに見えているか。文字の全体が、端のぼかしより内側にあれば見えているとする。
    /// ぼかしにかかる文字まで動かすと、短い宛先の返信のように、カプセルの行末のぼかしにかかった文字が入力欄の次の行の頭へ動き、前の行を横切ったため。
    func showsAnyCharacter(of range: Range<Int>, on line: Line) -> Bool {
        guard line.verticalRange.overlaps(window.minY ... window.maxY) else { return false }
        let visibleEnd = window.maxX - fade.right
        let visibleStart = window.minX + fade.left
        return range.contains { index in
            let start = line.origin.x + line.boundaries[index - line.range.lowerBound]
            let end = line.origin.x + line.boundaries[index - line.range.lowerBound + 1]
            return start >= visibleStart && end <= visibleEnd
        }
    }
}

/// 見える範囲の端から内側へ、透明から濃くしていく幅。
public struct TextMorphFade: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}
