import Foundation
import Testing
@testable import SciaCore

@MainActor
struct MediaTransfersTests {
    /// 落とす処理を、テストから進めたり終えたりできるようにする。
    @MainActor
    final class Network {
        struct Pending {
            let onProgress: @MainActor (Double) -> Void
            let continuation: CheckedContinuation<URL, any Error>
        }

        var pending: [URL: Pending] = [:]
        var cancelled: [URL] = []
        var saved: [URL] = []
        var saveError: (any Error)?
        /// 手元にあるファイル。落とさずにすぐ返す。
        var cached: Set<URL> = []

        func fetch(_ url: URL, _ onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
            if cached.contains(url) { return file(for: url) }
            onProgress(0)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[url] = Pending(onProgress: onProgress, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor in self.cancel(url) }
            }
        }

        private func cancel(_ url: URL) {
            cancelled.append(url)
            pending.removeValue(forKey: url)?.continuation.resume(throwing: CancellationError())
        }

        func progress(_ url: URL, _ fraction: Double) {
            pending[url]?.onProgress(fraction)
        }

        func complete(_ url: URL) {
            pending.removeValue(forKey: url)?.continuation.resume(returning: file(for: url))
        }

        func fail(_ url: URL) {
            pending.removeValue(forKey: url)?.continuation.resume(throwing: URLError(.notConnectedToInternet))
        }

        func save(_ file: URL) async throws {
            if let saveError { throw saveError }
            saved.append(file)
        }

        func file(for url: URL) -> URL {
            URL(filePath: "/tmp/\(url.lastPathComponent)")
        }
    }

    private let network = Network()
    private let transfers: MediaTransfers
    private var events: Events

    @MainActor
    final class Events {
        var all: [String] = []
    }

    init() {
        let network = network
        transfers = MediaTransfers(fetch: { try await network.fetch($0, $1) }, saveToPhotos: { try await network.save($0) })
        let events = Events()
        self.events = events
        transfers.onEvent = { event in
            let line = switch event {
            case .saved(let transfer): "saved \(transfer.target.url.lastPathComponent)"
            case .shareReady(let transfer, _): "share \(transfer.target.url.lastPathComponent)"
            case .failed(let transfer, let purpose, let failure):
                switch failure {
                case .download: "download failed \(purpose) \(transfer.target.url.lastPathComponent)"
                case .save: "save failed \(transfer.target.url.lastPathComponent)"
                }
            case .shareStopped(let transfer): "share stopped \(transfer.target.url.lastPathComponent)"
            }
            events.all.append(line)
        }
    }

    private func target(_ name: String, kind: MediaAttachment.Kind = .video) -> MediaTransfers.Target {
        MediaTransfers.Target(url: url(name), kind: kind, subject: nil)
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://media.example/\(name)") ?? URL(filePath: "/")
    }

    /// 落とす処理が始まるのを待つ。
    private func waitUntilFetching(_ names: String...) async throws {
        try await waitUntil { names.allSatisfy { network.pending[url($0)] != nil } }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test func savesDownloadInParallelAndReportInCompletionOrder() async throws {
        transfers.start(.save, target("a.mp4"))
        transfers.start(.save, target("b.mp4"))
        try await waitUntilFetching("a.mp4", "b.mp4")
        #expect(transfers.transfers.count == 2)

        network.complete(url("b.mp4"))
        try await waitUntil { events.all.count == 1 }
        network.complete(url("a.mp4"))
        try await waitUntil { events.all.count == 2 }

        #expect(events.all == ["saved b.mp4", "saved a.mp4"])
        #expect(network.saved == [network.file(for: url("b.mp4")), network.file(for: url("a.mp4"))])
        #expect(transfers.transfers.isEmpty)
    }

    @Test func newShareStopsPreviousShareButNotSaves() async throws {
        transfers.start(.save, target("saved.mp4"))
        transfers.start(.share, target("first.mp4"))
        try await waitUntilFetching("saved.mp4", "first.mp4")

        transfers.start(.share, target("second.mp4"))
        try await waitUntilFetching("second.mp4")
        try await waitUntil { network.cancelled == [url("first.mp4")] }

        #expect(transfers.transfers.map(\.target.url.lastPathComponent) == ["saved.mp4", "second.mp4"])
        // 前の共有を止めたことは、使う人が新しく始めた結果なので知らせない。
        #expect(events.all.isEmpty)
    }

    @Test func savingAndSharingSameFileDownloadsOnce() async throws {
        transfers.start(.save, target("a.mp4"))
        try await waitUntilFetching("a.mp4")
        transfers.start(.share, target("a.mp4"))

        #expect(transfers.transfers.count == 1)
        #expect(transfers.transfers.first?.purposes == [.save, .share])

        network.complete(url("a.mp4"))
        try await waitUntil { events.all.count == 2 }
        #expect(events.all == ["share a.mp4", "saved a.mp4"])
    }

    @Test func closingViewerStopsSharingAndKeepsSaving() async throws {
        transfers.start(.share, target("shared.mp4"))
        transfers.start(.save, target("saved.mp4"))
        transfers.start(.save, target("both.mp4"))
        transfers.start(.share, target("both.mp4"))
        try await waitUntilFetching("saved.mp4", "both.mp4")

        transfers.stopSharing()

        // 共有は1つだけなので、both.mp4の共有を始めた時点でshared.mp4の共有は止まっている。
        #expect(events.all == ["share stopped both.mp4"])
        #expect(transfers.transfers.map(\.target.url.lastPathComponent) == ["saved.mp4", "both.mp4"])
        #expect(transfers.transfers.allSatisfy { $0.purposes == [.save] })
        network.complete(url("both.mp4"))
        try await waitUntil { events.all.count == 2 }
        #expect(events.all.last == "saved both.mp4")
    }

    @Test func closingViewerStopsShareOnlyDownload() async throws {
        transfers.start(.share, target("a.mp4"))
        try await waitUntilFetching("a.mp4")
        transfers.stopSharing()

        #expect(events.all == ["share stopped a.mp4"])
        #expect(transfers.transfers.isEmpty)
        try await waitUntil { network.cancelled == [url("a.mp4")] }
    }

    @Test func closingAnotherViewerKeepsSharing() async throws {
        let id = transfers.start(.share, target("a.mp4"))
        try await waitUntilFetching("a.mp4")

        transfers.stopSharing { $0.id != id }

        #expect(transfers.transfers.map(\.id) == [id])
        #expect(events.all.isEmpty)
        network.complete(url("a.mp4"))
        try await waitUntil { events.all == ["share a.mp4"] }
    }

    @Test func stoppedTransferIsNotReported() async throws {
        transfers.start(.save, target("a.mp4"))
        try await waitUntilFetching("a.mp4")
        let id = try #require(transfers.transfers.first?.id)

        transfers.stop(id)

        try await waitUntil { network.cancelled == [url("a.mp4")] }
        #expect(transfers.transfers.isEmpty)
        #expect(events.all.isEmpty)
        #expect(network.saved.isEmpty)
    }

    @Test func failuresAreReportedWithPurpose() async throws {
        transfers.start(.share, target("shared.mp4"))
        transfers.start(.save, target("saved.mp4"))
        try await waitUntilFetching("shared.mp4", "saved.mp4")

        network.fail(url("shared.mp4"))
        try await waitUntil { events.all.count == 1 }
        network.saveError = CocoaError(.fileWriteOutOfSpace)
        network.complete(url("saved.mp4"))
        try await waitUntil { events.all.count == 2 }

        #expect(events.all == ["download failed share shared.mp4", "save failed saved.mp4"])
        #expect(transfers.transfers.isEmpty)
    }

    @Test func progressIsKeptUntilSavingFinishes() async throws {
        transfers.start(.save, target("a.mp4"))
        #expect(transfers.transfers.first?.isVisible == false)
        try await waitUntilFetching("a.mp4")
        #expect(transfers.transfers.first?.fraction == 0)

        network.progress(url("a.mp4"), 0.42)
        #expect(transfers.transfers.first?.fraction == 0.42)
        #expect(transfers.transfers.first?.isStoppable == true)
    }

    @Test func cachedFileIsNeverShown() async throws {
        network.cached = [url("a.png")]
        var shownCount = 0
        transfers.onChange = { [transfers] in
            shownCount += transfers.transfers.filter(\.isVisible).count
        }
        transfers.start(.save, target("a.png", kind: .image))
        try await waitUntil { events.all == ["saved a.png"] }
        #expect(shownCount == 0)
    }

    @Test func viewerChipShowsCurrentAttachmentAndCountsOthers() {
        let current = transfer("current.mp4", fraction: 0.42)
        let other = transfer("other.mp4", fraction: 0.1)
        let hidden = transfer("cached.png", fraction: nil)

        #expect(MediaTransferChip.viewer([current, other, hidden], currentURL: url("current.mp4")) == .single(current, others: 1))
        #expect(MediaTransferChip.viewer([current, other, hidden], currentURL: url("none.mp4")) == .count(2))
        #expect(MediaTransferChip.viewer([other], currentURL: url("none.mp4")) == .count(1))
        #expect(MediaTransferChip.viewer([hidden], currentURL: url("cached.png")) == nil)
    }

    @Test func timelineChipShowsProgressOnlyForSingleTransfer() {
        let first = transfer("first.mp4", fraction: 0.42)
        let second = transfer("second.mp4", fraction: 0.1)

        #expect(MediaTransferChip.timeline([first]) == .single(first, others: 0))
        #expect(MediaTransferChip.timeline([first, second]) == .count(2))
        #expect(MediaTransferChip.timeline([transfer("cached.png", fraction: nil)]) == nil)
    }

    /// 落としている途中の状態を作る。
    private func transfer(_ name: String, fraction: Double?) -> MediaTransfers.Transfer {
        var transfer = MediaTransfers.Transfer(id: UUID(), target: target(name), purposes: [.save])
        transfer.fraction = fraction
        return transfer
    }
}
