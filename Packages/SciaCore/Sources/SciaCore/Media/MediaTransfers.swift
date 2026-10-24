public import Foundation

/// 共有や保存のために、添付ファイルの元のファイルを用意する処理。ビューアを閉じても保存を続けられるよう、ビューアの外（セッション）で持つ。
/// 決まりはdocs/notices.mdの「場面ごと」の「ダウンロード」と「複数のダウンロード」にある。
///
/// 保存は並べて落とし、済んだ順に知らせる。共有は1つだけにし、新しく始めたら前の共有の分を止める。
/// 同じファイルを保存と共有の両方に求めたら、1回だけ落として両方に使う。
@MainActor
public final class MediaTransfers {
    public enum Purpose: Sendable, Hashable {
        case save
        case share
    }

    /// 用意するファイルと、知らせに使うその持ち主。
    public struct Target: Sendable, Equatable {
        public let url: URL
        /// 失敗をどの添付ファイルのものか分かる文言にするために持つ。
        public let kind: MediaAttachment.Kind
        /// 添付ファイルの投稿。「操作の状況」の行から投稿を開くために持つ。
        public let subject: OperationStatus.Subject?

        public init(url: URL, kind: MediaAttachment.Kind, subject: OperationStatus.Subject?) {
            self.url = url
            self.kind = kind
            self.subject = subject
        }
    }

    public struct Transfer: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let target: Target
        public internal(set) var purposes: Set<Purpose>
        /// 落とし始めてからの進み具合。0から1。全体の大きさが分かるまでは0。手元にあって落としていなければnil。
        public internal(set) var fraction: Double?
        /// 落とし終えて写真に足している。もう止められない。
        public internal(set) var isFinishing = false

        /// 知らせに出すか。手元にあったものはすぐ済むため、落とし始めたものだけを出す。
        public var isVisible: Bool { fraction != nil }
        /// 止められるか。写真に足し始めたら止められない。
        public var isStoppable: Bool { !isFinishing }
    }

    /// 済んだこと、失敗したこと。受けた側が、開いているビューアか一覧に知らせる。
    public enum Event {
        /// 写真に保存した。
        case saved(Transfer)
        /// 共有に渡すファイルを用意した。
        case shareReady(Transfer, file: URL)
        /// 落とせなかったか、写真に足せなかった。`purpose`は失敗した操作で、保存と共有の両方を求めていたら保存にする。
        case failed(Transfer, purpose: Purpose, Failure)
        /// ビューアを閉じたため、共有のために落としている途中のものを止めた。
        case shareStopped(Transfer)
    }

    public enum Failure {
        case download(any Error)
        case save(any Error)
    }

    /// `url`のファイルの、共有や保存に渡すコピーを返す。手元になければ落とし、落とし始めたら0を、そのあと進み具合を0から1で`onProgress`に渡す。
    /// 呼び出し側のタスクを取り消したら、通信も止める。
    public typealias Fetch = @MainActor (_ url: URL, _ onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL
    /// ファイルを写真に足す。
    public typealias SaveToPhotos = @MainActor (URL) async throws -> Void

    /// 始めた順。済んだもの、止めたもの、失敗したものは外す。
    public private(set) var transfers: [Transfer] = []
    /// `transfers`が変わった。
    public var onChange: (@MainActor () -> Void)?
    /// 済んだか失敗した。呼ぶ時点で、そのものは`transfers`から外してある。
    public var onEvent: (@MainActor (Event) -> Void)?

    private let fetch: Fetch
    private let saveToPhotos: SaveToPhotos
    private var tasks: [Transfer.ID: Task<Void, Never>] = [:]
    /// 走り終えていない処理の数。止めたものも、取り消しを受けて戻り切るまで数える。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public private(set) var runningCount = 0

    public init(fetch: @escaping Fetch, saveToPhotos: @escaping SaveToPhotos) {
        self.fetch = fetch
        self.saveToPhotos = saveToPhotos
    }

    public func transfer(_ id: Transfer.ID) -> Transfer? {
        transfers.first { $0.id == id }
    }

    /// `target`のファイルを用意して、`purpose`の操作をする。
    /// 共有なら、ほかのファイルの共有のために落としている途中のものを止める。同じファイルを落としている途中なら、落とし直さずに操作を足す。
    /// - Returns: 操作を受け持つもののid。
    @discardableResult
    public func start(_ purpose: Purpose, _ target: Target) -> Transfer.ID {
        if purpose == .share {
            dropSharing { $0.target.url != target.url }
        }
        let id: Transfer.ID
        if let index = transfers.firstIndex(where: { $0.target.url == target.url && ($0.purposes.contains(purpose) || !$0.isFinishing) }) {
            transfers[index].purposes.insert(purpose)
            id = transfers[index].id
        } else {
            let transfer = Transfer(id: UUID(), target: target, purposes: [purpose])
            transfers.append(transfer)
            runningCount += 1
            tasks[transfer.id] = Task { [weak self] in
                await self?.run(transfer.id)
                self?.runningCount -= 1
            }
            id = transfer.id
        }
        onChange?()
        return id
    }

    /// 使う人が止めた。知らせは出さない。写真に足し始めていたら止めない。
    public func stop(_ id: Transfer.ID) {
        guard let transfer = transfer(id), transfer.isStoppable else { return }
        cancel(id)
        onChange?()
    }

    /// ビューアを閉じたので、共有のために落としている途中のものを止める。保存も求めていれば、保存のために落とし続ける。
    /// 知らせに出していたものは、止めたことを`shareStopped`で伝える。
    /// - Parameter shouldStop: 止めるもの。Macではビューアを別々のウィンドウで開くため、閉じたビューアで始めたものだけを止める。
    public func stopSharing(where shouldStop: (Transfer) -> Bool = { _ in true }) {
        let stopped = dropSharing(where: shouldStop)
        onChange?()
        for transfer in stopped where transfer.isVisible {
            onEvent?(.shareStopped(transfer))
        }
    }

    /// `shouldDrop`に当てはまるものから、共有を外す。ほかに求めている操作がなければ止める。外したものを返す。
    @discardableResult
    private func dropSharing(where shouldDrop: (Transfer) -> Bool) -> [Transfer] {
        var dropped: [Transfer] = []
        for transfer in transfers where transfer.purposes.contains(.share) && !transfer.isFinishing && shouldDrop(transfer) {
            dropped.append(transfer)
            if transfer.purposes == [.share] {
                cancel(transfer.id)
            } else if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
                transfers[index].purposes.remove(.share)
            }
        }
        return dropped
    }

    private func cancel(_ id: Transfer.ID) {
        tasks.removeValue(forKey: id)?.cancel()
        transfers.removeAll { $0.id == id }
    }

    private func run(_ id: Transfer.ID) async {
        guard let url = transfer(id)?.target.url else { return }
        let file: URL
        do {
            file = try await fetch(url) { [weak self] fraction in
                self?.update(id) { $0.fraction = fraction }
            }
        } catch {
            finish(id) { .failed($0, purpose: $0.purposes.contains(.save) ? .save : .share, .download(error)) }
            return
        }
        guard var transfer = transfer(id) else { return }
        if transfer.purposes.contains(.share) {
            transfer.purposes.remove(.share)
            if transfer.purposes.isEmpty {
                finish(id) { _ in .shareReady(transfer, file: file) }
                return
            }
            update(id) { $0.purposes.remove(.share) }
            onEvent?(.shareReady(transfer, file: file))
        }
        update(id) { $0.isFinishing = true }
        do {
            try await saveToPhotos(file)
            finish(id) { .saved($0) }
        } catch {
            finish(id) { .failed($0, purpose: .save, .save(error)) }
        }
    }

    private func update(_ id: Transfer.ID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
        onChange?()
    }

    /// 外してから知らせる。止めたあとに届いた結果は捨てる。
    private func finish(_ id: Transfer.ID, event: (Transfer) -> Event) {
        guard let transfer = transfer(id) else { return }
        tasks[id] = nil
        transfers.removeAll { $0.id == id }
        onEvent?(event(transfer))
        onChange?()
    }
}

/// 知らせのチップに出す、落としている途中のもの。決まりはdocs/notices.mdの「複数のダウンロード」にある。
public enum MediaTransferChip: Equatable {
    /// 1つのものの進み具合を出し、ほかを件数で添える。
    case single(MediaTransfers.Transfer, others: Int)
    /// どれの進み具合も出さず、件数だけを出す。
    case count(Int)

    /// ビューアのチップ。いま見ている添付ファイルのものを出し、ほかは件数で添える。いま見ているものがなければ件数だけを出す。
    /// - Parameter currentURL: いま見ている添付ファイルのファイルのURL。
    public static func viewer(_ transfers: [MediaTransfers.Transfer], currentURL: URL?) -> MediaTransferChip? {
        let visible = transfers.filter(\.isVisible)
        guard !visible.isEmpty else { return nil }
        if let current = visible.last(where: { $0.target.url == currentURL }) {
            return .single(current, others: visible.count - 1)
        }
        return .count(visible.count)
    }

    /// ビューアを閉じたあとの一覧のチップ。1つなら進み具合を、2つ以上なら件数を出す。
    public static func timeline(_ transfers: [MediaTransfers.Transfer]) -> MediaTransferChip? {
        let visible = transfers.filter(\.isVisible)
        switch visible.count {
        case 0: return nil
        case 1: return .single(visible[0], others: 0)
        default: return .count(visible.count)
        }
    }
}
