import os

/// 一覧の既読位置をサーバーに保存する決まり。`FeedTimelineModel`と`NotificationsModel`が持つ。
///
/// 保存するのは次のとき。どれも、保存済みより進んでいるときだけ送る。
/// - 読み進めたあと、`TuningCatalog.readPositionSaveDelay`の間進まず、操作もしていないとき。呼ぶ側が操作の終わりを知らせなくても保存するため
/// - 操作が止まったとき（`saveNow`）。待たずに保存する
/// - バックグラウンドに入るとき（`saveNow(inBackground: true)`）。保存し終えるまでアプリを止めないよう頼む
/// - 保存し終えるまで待ちたいとき（`saveAndWait()`）
///
/// 保存している間に読み進めた分も、続けて保存する。失敗したら`onFailure`に渡し、次の機会に保存し直す。
@MainActor
final class ReadPositionSaver {
    /// 保存する目印の名前。ログとバックグラウンドの延長の名前に使う。
    private let name: String
    private let tasks: TaskScope
    private let clock: any Clock<Duration>
    private let tuning: TuningStore
    private let backgroundTime: @MainActor (String, _ onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void
    /// 保存済みより進んだ既読位置。進んでいなければnil。
    private let readIDToSave: @MainActor () -> String?
    /// 既読位置をサーバーに送る。
    private let save: @MainActor (String) async throws -> Void
    /// 送れた既読位置を、保存済みとして覚える。
    private let markSaved: @MainActor (String) -> Void
    /// 使う人が一覧を操作している最中か。最中なら、待って保存するのを操作が止まるまで延ばす。
    private let isUserInteracting: @MainActor () -> Bool
    private let onFailure: @MainActor (any Error) -> Void
    private let logger = SciaLog.logger(category: "timeline")
    private var saving: Task<Void, Never>?
    /// 最後に読み進めてから経った長さ。読み進めた分を待って保存し終えたらnil。
    private var sinceAdvanced: (@Sendable () -> Duration)?
    private var waiting: Task<Void, Never>?
    /// バックグラウンドで保存を終えるまで、アプリを止めないよう頼んでいる。終えるときに呼ぶ。
    private var endBackgroundTime: (@MainActor () -> Void)?

    init(
        name: String,
        tasks: TaskScope,
        clock: any Clock<Duration>,
        tuning: TuningStore,
        backgroundTime: @escaping @MainActor (String, _ onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void,
        readIDToSave: @escaping @MainActor () -> String?,
        save: @escaping @MainActor (String) async throws -> Void,
        markSaved: @escaping @MainActor (String) -> Void,
        isUserInteracting: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        self.name = name
        self.tasks = tasks
        self.clock = clock
        self.tuning = tuning
        self.backgroundTime = backgroundTime
        self.readIDToSave = readIDToSave
        self.save = save
        self.markSaved = markSaved
        self.isUserInteracting = isUserInteracting
        self.onFailure = onFailure
    }

    /// 走り終えていない、待つ処理と保存する処理があるか。テストで、何も残っていないことを確かめるのに使う。
    var isIdle: Bool { saving == nil && waiting == nil }

    /// 既読位置が進んだときに呼ぶ。進まなくなって決まった時間が経ったら保存する。
    func didAdvance() {
        guard !tasks.isClosed else { return }
        sinceAdvanced = stopwatch(on: clock)
        guard waiting == nil else { return }
        waiting = tasks.run(.display) { [weak self, clock] in
            while let self, let sinceAdvanced = self.sinceAdvanced {
                let remaining = Duration.seconds(self.tuning.value(of: TuningCatalog.readPositionSaveDelay)) - sinceAdvanced()
                if remaining <= .zero {
                    // 操作の最中なら、止まったときの`saveNow`か、止まってから待った後に保存する。
                    guard self.isUserInteracting() else { break }
                    self.sinceAdvanced = stopwatch(on: clock)
                    continue
                }
                guard (try? await clock.sleep(for: remaining)) != nil else { return }
            }
            self?.waiting = nil
            self?.sinceAdvanced = nil
            self?.saveNow()
        }
    }

    /// 待たずに保存を始める。
    /// - Parameter inBackground: バックグラウンドに入るときならtrue。保存し終えるまで（保存中の分も含めて）アプリを止めないよう頼む。
    func saveNow(inBackground: Bool = false) {
        guard !tasks.isClosed, readIDToSave() != nil || saving != nil else { return }
        if inBackground, endBackgroundTime == nil {
            endBackgroundTime = backgroundTime("save \(name) marker") { [weak self] in
                // 尽きたら、次にバックグラウンドへ入ったときに頼み直す。
                self?.endBackgroundTask()
            }
        }
        guard saving == nil else { return }
        // 既読位置の保存は、スクロールやバックグラウンドへの移行で自動で送る。
        saving = tasks.run(.display) { [weak self] in
            while let self, !self.tasks.isClosed, let id = self.readIDToSave() {
                do {
                    try await self.save(id)
                    self.markSaved(id)
                    self.logger.info("\(self.name, privacy: .public) marker saved id=\(id, privacy: .public)")
                } catch {
                    self.onFailure(error)
                    break
                }
            }
            self?.saving = nil
            self?.endBackgroundTask()
        }
    }

    /// 待たずに保存を始め、保存し終えるまで待つ。保存している途中なら、その分と、続けて読み進めた分を保存し終えるまで待つ。
    func saveAndWait() async {
        saveNow()
        await saving?.value
    }

    /// 待って保存するのをやめる。バックグラウンドに入るときに、その場で保存するのに合わせて呼ぶ。
    func cancelWaiting() {
        waiting?.cancel()
        waiting = nil
        sinceAdvanced = nil
    }

    private func endBackgroundTask() {
        guard let end = endBackgroundTime else { return }
        endBackgroundTime = nil
        end()
    }
}
