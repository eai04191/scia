public import Foundation

/// 落ちたフレームで、メインスレッドの何に時間を使ったかを、処理の名前ごとに足し上げたもの。
///
/// 落ちたフレームを数えるだけでは、何が重かったかは分からず、再現させてプロファイラーを当てるしかない。
/// そこで、重くなりやすい処理の時間をスクロールの間だけ測り、落ちたフレームに使ったものを残す。ふだん使っている間に溜めれば、どこを直すかを機械的に選べる。
/// 測るのは決めた処理だけなので、`measured`が`hitchTime`よりずっと小さければ、測っていない処理が重い。
public struct FrameWorkTally: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        /// 落ちたフレームで、この処理に使った時間の合計（秒）。
        public var total: Double
        /// 落ちたフレームで、この処理を呼んだ回数。
        public var count: Int
        /// 1回の呼び出しで一番長かった時間（秒）。
        public var longest: Double
        /// この処理を含んでいた、落ちたフレームの数。
        public var frames: Int

        public init(total: Double, count: Int, longest: Double, frames: Int) {
            self.total = total
            self.count = count
            self.longest = longest
            self.frames = frames
        }

        mutating func merge(_ other: Entry) {
            total += other.total
            count += other.count
            longest = max(longest, other.longest)
            frames += other.frames
        }
    }

    public private(set) var entries: [String: Entry]
    /// 落ちたフレームの数。
    public private(set) var droppedFrames: Int
    /// 予定より遅れた時間の合計（秒）。
    public private(set) var hitchTime: Double
    /// フレームが落ちたスクロールの回数。
    public private(set) var scrolls: Int

    public init(entries: [String: Entry] = [:], droppedFrames: Int = 0, hitchTime: Double = 0, scrolls: Int = 0) {
        self.entries = entries
        self.droppedFrames = droppedFrames
        self.hitchTime = hitchTime
        self.scrolls = scrolls
    }

    public var isEmpty: Bool { droppedFrames == 0 }

    /// 測った処理の時間の合計（秒）。
    public var measured: Double { entries.values.reduce(0) { $0 + $1.total } }

    /// 時間の長い順。同じ時間なら名前の順にして、並びを決める。
    public func top(_ count: Int) -> [(name: String, entry: Entry)] {
        entries
            .map { (name: $0.key, entry: $0.value) }
            .sorted { ($0.entry.total, $1.name) > ($1.entry.total, $0.name) }
            .prefix(count)
            .map { $0 }
    }

    /// ほかの集計を足す。起動をまたいで溜めるのに使う。
    public mutating func merge(_ other: FrameWorkTally) {
        entries.merge(other.entries) { current, new in
            var merged = current
            merged.merge(new)
            return merged
        }
        droppedFrames += other.droppedFrames
        hitchTime += other.hitchTime
        scrolls += other.scrolls
    }

    mutating func addFrame(_ work: [String: Entry], dropped: Int, delay: Double) {
        merge(FrameWorkTally(entries: work, droppedFrames: dropped, hitchTime: delay))
    }

    mutating func countScroll() {
        scrolls += 1
    }

    /// ログの1行。時間はミリ秒で、名前ごとに「合計/回数/最長」。
    public var logLine: String {
        let top = top(5).map { "\($0.name):\(Self.ms($0.entry.total))/\($0.entry.count)/\(Self.ms($0.entry.longest))" }
        return "dropped=\(droppedFrames) hitchMs=\(Self.ms(hitchTime)) measuredMs=\(Self.ms(measured)) top=\(top.joined(separator: ","))"
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}

/// 1回のスクロールの間、画面の更新ごとに落ちたフレームを数え、落ちたフレームに使った処理を`FrameWorkTally`に足す。
/// 画面の更新の合間に測った処理は、次の更新の時刻を待たせたものとして、次に届いた更新のフレームに割り当てる。
public struct FrameWorkLedger: Sendable {
    private var hitches = HitchCounter()
    private var pending: [String: FrameWorkTally.Entry] = [:]
    public private(set) var tally = FrameWorkTally()

    public init() {}

    public var summary: HitchCounter.Summary { hitches.summary }

    /// メインスレッドで測った処理を1回分足す。入れ子の処理は、内側の時間を引いてから渡す。
    public mutating func add(_ name: String, seconds: Double) {
        let entry = FrameWorkTally.Entry(total: seconds, count: 1, longest: seconds, frames: 0)
        pending[name, default: FrameWorkTally.Entry(total: 0, count: 0, longest: 0, frames: 0)].merge(entry)
    }

    /// 画面の更新ごとに、`CADisplayLink`の`timestamp`と`targetTimestamp`を渡す。
    public mutating func frame(timestamp: Double, targetTimestamp: Double) {
        let before = hitches.summary
        hitches.record(timestamp: timestamp, targetTimestamp: targetTimestamp)
        let after = hitches.summary
        defer { pending = [:] }
        guard after.droppedFrames > before.droppedFrames else { return }
        let work = pending.mapValues { entry in
            var counted = entry
            counted.frames = 1
            return counted
        }
        tally.addFrame(work, dropped: after.droppedFrames - before.droppedFrames, delay: after.hitchTime - before.hitchTime)
    }

    /// スクロールを終えた。フレームが落ちていれば、スクロールの回数を数えた集計を返す。
    public mutating func finish() -> FrameWorkTally {
        pending = [:]
        if !tally.isEmpty {
            tally.countScroll()
        }
        return tally
    }
}

/// `FrameWorkTally`を、起動をまたいで1つのJSONファイルに足し上げる。
public struct FrameWorkStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// 保存してある集計。まだなければ空。
    public func load() throws -> FrameWorkTally {
        guard FileManager.default.fileExists(atPath: file.path()) else { return FrameWorkTally() }
        return try JSONDecoder().decode(FrameWorkTally.self, from: Data(contentsOf: file))
    }

    /// 保存してある集計に足して書き直し、足したあとの集計を返す。
    @discardableResult
    public func add(_ tally: FrameWorkTally) throws -> FrameWorkTally {
        var total = try load()
        total.merge(tally)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(total).write(to: file, options: .atomic)
        return total
    }
}
