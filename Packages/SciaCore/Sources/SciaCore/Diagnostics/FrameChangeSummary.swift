/// 表示の時計が刻むたびに読んだ値から、刻みの間隔と、値が何刻みごとに変わったかをまとめる。
/// 動きが毎コマ描かれているかを、ベンチマークで数えるため。
public struct FrameChangeSummary: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        /// 刻みの時刻（秒）。
        public let time: Double
        public let value: Double

        public init(time: Double, value: Double) {
            self.time = time
            self.value = value
        }
    }

    /// 値が最初に変わった刻みから最後に変わった刻みまでの刻みの数。
    public let ticks: Int
    /// 値が変わった回数。
    public let changes: Int
    /// その範囲の刻みの間隔の中央値（秒）。
    public let medianTickInterval: Double
    /// 値が変わってから次に変わるまでの刻みの数ごとの回数。毎コマ動けば1だけになる。
    public let changeGaps: [Int: Int]

    /// 値が2回以上変わらなければ、範囲を決められないのでnil。
    public init?(samples: [Sample]) {
        let changed = samples.indices.dropFirst().filter { samples[$0].value != samples[$0 - 1].value }
        guard let first = changed.first, let last = changed.last, first < last else { return nil }
        ticks = last - first + 1
        changes = changed.count
        let intervals = (first + 1 ... last).map { samples[$0].time - samples[$0 - 1].time }.sorted()
        medianTickInterval = intervals[intervals.count / 2]
        changeGaps = Dictionary(grouping: zip(changed, changed.dropFirst()).map { $1 - $0 }, by: { $0 }).mapValues(\.count)
    }

    /// 例: 刻み=120 変化=120 刻みの間隔=8.3ms 変化の間隔: 1刻み×119
    public var text: String {
        let gaps = changeGaps.sorted { $0.key < $1.key }.map { "\($0.key)刻み×\($0.value)" }.joined(separator: " ")
        let interval = (medianTickInterval * 10000).rounded() / 10
        return "刻み=\(ticks) 変化=\(changes) 刻みの間隔=\(interval)ms 変化の間隔: \(gaps)"
    }
}
