import SafariServices
import SciaCore
import SwiftUI

/// アプリが端末で使っている大きさを置き場所ごとに見せ、消してよいものを消す画面。
struct StorageView: View {
    /// 測る処理と消す処理。部品カタログでは、ファイルに触れずに状態を作るために差し替える。
    struct Actions {
        var measure: @Sendable () async -> StorageBreakdown
        var remove: @Sendable (StorageBreakdown.Category) async throws -> Void
        /// メディアのキャッシュの、表示済みの段の中身を並べる画面の処理。
        var mediaFiles: MediaCacheView.Actions
        /// メディアのキャッシュの、先読みの段の中身を並べる画面の処理。
        var mediaPrefetch: MediaCacheView.Actions
    }

    let actions: Actions
    @State private var breakdown: StorageBreakdown?
    /// 消している途中のボタン。消し終えて測り直すまで、ほかのボタンも押せないようにする。
    @State private var removing: StorageRemoveTarget?
    @State private var removeError: ErrorPresentation?
    /// 消す前に確かめているボタン。キャッシュと違い、消すと困ることがあるものだけ確かめる。
    @State private var confirming: StorageRemoveTarget?

    /// - Parameters:
    ///   - removing: 消している途中のボタン。部品カタログで、消している途中の見た目を作るために渡す。
    ///   - removeError: 消せなかったときの説明。部品カタログで、失敗の見た目を作るために渡す。
    init(actions: Actions = .app, removing: StorageRemoveTarget? = nil, removeError: ErrorPresentation? = nil) {
        self.actions = actions
        _removing = State(initialValue: removing)
        _removeError = State(initialValue: removeError)
    }

    var body: some View {
        List {
            if let breakdown {
                Section {
                    ForEach(breakdown.items.filter { $0.category.isShown(bytes: $0.bytes) }, id: \.category) { item in
                        switch item.category {
                        case .mediaFiles:
                            mediaCacheRows(viewed: item, prefetched: breakdown.item(.mediaPrefetch))
                        case .mediaPrefetch:
                            // メディアのキャッシュの下の段に並べる。
                            EmptyView()
                        default:
                            LabeledContent(item.category.title, value: Self.text(item.bytes))
                        }
                    }
                    LabeledContent {
                        Text(Self.text(breakdown.dataBytes))
                    } label: {
                        Text(StorageBreakdown.totalTitle).bold()
                    }
                } header: {
                    Text(StorageBreakdown.dataHeader)
                } footer: {
                    if breakdown.hasUnmeasuredItems {
                        Text(StorageBreakdown.unmeasuredFooter)
                    }
                }
                Section {
                    ForEach(StorageRemoveTarget.shown(in: breakdown), id: \.self) { target in
                        removeButton(target, bytes: target.removableBytes(in: breakdown))
                    }
                } footer: {
                    if let removeError {
                        FailureReason(reason: removeError, lead: SettingsTexts.Storage.removeFailureLead)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    LabeledContent(StorageBreakdown.appTitle, value: Self.text(breakdown.appBytes))
                } footer: {
                    Text(SettingsTexts.Storage.appSizeFooter)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView(SettingsTexts.Storage.measuring)
                    Spacer()
                }
            }
        }
        .navigationTitle(SettingsPage.storage.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) {
            breakdown = await actions.measure()
        }
        .confirmationDialog(
            confirming?.confirmationTitle ?? "",
            isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
            titleVisibility: .visible,
            presenting: confirming
        ) { target in
            Button(SettingsTexts.Storage.remove, role: .destructive) { remove(target) }
        } message: { target in
            Text(target.confirmationMessage ?? "")
        }
    }

    /// メディアのキャッシュを、合計の行の下に、表示済みと先読みの2段に分けて並べる。
    /// 置き場の違う2つを1つの項目として数えつつ、それぞれの大きさと中身を見られるようにする（docs/image-loading.md）。
    @ViewBuilder
    private func mediaCacheRows(viewed: StorageBreakdown.Item, prefetched: StorageBreakdown.Item?) -> some View {
        let total: Int64? = if let viewedBytes = viewed.bytes, let prefetchedBytes = prefetched?.bytes { viewedBytes + prefetchedBytes } else { nil }
        LabeledContent(StorageBreakdown.mediaCacheTitle, value: Self.text(total))
        // 中身を見返して、共有や保存をできるようにする。
        NavigationLink {
            MediaCacheView(category: .mediaFiles, actions: actions.mediaFiles)
        } label: {
            LabeledContent(SettingsPage.viewedMediaCache.rowTitle, value: Self.text(viewed.bytes))
                .padding(.leading, Self.subrowIndent)
        }
        NavigationLink {
            MediaCacheView(category: .mediaPrefetch, actions: actions.mediaPrefetch)
        } label: {
            LabeledContent(SettingsPage.prefetchedMediaCache.rowTitle, value: Self.text(prefetched?.bytes))
                .padding(.leading, Self.subrowIndent)
        }
    }

    /// メディアのキャッシュの下の段を、合計の行より下げる幅。
    private static let subrowIndent: CGFloat = 16

    /// 消せる大きさは、上の内訳の値と同じなので出さない。値を並べると、内訳と同じ押せない行の形になるため。
    /// `bytes`がnilなら、測れないだけで消せるものがあるかもしれないので、押せるままにする。
    private func removeButton(_ target: StorageRemoveTarget, bytes: Int64?) -> some View {
        Button {
            if target.confirmationMessage != nil {
                confirming = target
            } else {
                remove(target)
            }
        } label: {
            HStack {
                Text(target.removeTitle)
                Spacer()
                if removing == target {
                    ProgressView()
                }
            }
        }
        .disabled(removing != nil || bytes == 0)
    }

    /// 項目を順に消す。1つ消せなくても残りは消し、最初に消せなかった理由を出す。
    private func remove(_ target: StorageRemoveTarget) {
        removing = target
        removeError = nil
        Task(.withoutRequests) {
            for category in target.categories {
                do {
                    try await actions.remove(category)
                } catch {
                    if removeError == nil { removeError = ErrorPresentation(error) }
                }
            }
            breakdown = await actions.measure()
            removing = nil
        }
    }

    /// iPhoneの設定と同じく、1000バイトを1KBとして、大きさに合った単位で書く。測れないときは「不明」。
    static func text(_ bytes: Int64?) -> String {
        bytes?.formatted(.byteCount(style: .file)) ?? StorageBreakdown.unmeasuredValue
    }
}

extension StorageView.Actions {
    @MainActor
    static var app: Self {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("Info.plistにCFBundleIdentifierがない")
        }
        let locations = StorageLocations(
            container: URL.homeDirectory,
            mediaFiles: AppDependencies.mediaFiles.directory,
            mediaPrefetch: AppDependencies.mediaPrefetchFiles.directory,
            temporary: URL.temporaryDirectory,
            discomfortReports: AppDependencies.discomfortReports.directory,
            preferences: URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory),
            // URLCacheがファイルを置く場所と名前は公開されていない。iOS 27のシミュレーターで、`URLSession.shared`の応答がここに入るのを確かめた。
            // `currentDiskUsage`は消した直後に古い値を返したため、ファイルを測る。場所が変わると0と数え、その分は「その他」に入る。消すのは公開されたAPIで行う。
            customEmojis: [AppDependencies.emojiImageDirectory, AppDependencies.customEmojis.directory],
            networkCache: ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"].map {
                URL.cachesDirectory.appending(fileName: SafeFileName(bundleIdentifier), directoryHint: .isDirectory).appending(fileName: SafeFileName($0))
            },
            // SFSafariViewControllerがデータを置く場所は公開されていない。iOS 27のシミュレーターで、ここに置くのを確かめた。
            // 場所が変わると0と数え、その分は「その他」に入る。消すのは公開されたAPIで行うので、場所が変わっても消せる。
            inAppSafari: URL.homeDirectory.appending(path: "SystemData/com.apple.SafariViewService", directoryHint: .isDirectory),
            sharedContainer: SharedMediaInbox.app?.root,
            appBundle: Bundle.main.bundleURL
        )
        let launchDate = AppDependencies.processStartDate
        let mediaFiles = AppDependencies.mediaFiles
        let mediaPrefetchFiles = AppDependencies.mediaPrefetchFiles
        let discomfortReports = AppDependencies.discomfortReports
        let clock = AppDependencies.clock
        let customEmojis = AppDependencies.customEmojis
        let emojiImageFiles = AppDependencies.emojiImageFiles
        let oversizedEmojis = AppDependencies.oversizedEmojis
        let emojiThumbnails = AppDependencies.emojiThumbnails
        return Self(
            measure: { await measure(locations, launchDate: launchDate) },
            remove: { category in
                switch category {
                case .mediaFiles:
                    try await mediaFiles.removeCachedFiles()
                case .mediaPrefetch:
                    try await mediaPrefetchFiles.removeCachedFiles()
                case .customEmojis:
                    try await emojiImageFiles.removeCachedFiles()
                    oversizedEmojis.removeAll()
                    await emojiThumbnails.removeAll()
                    await customEmojis.removeAll()
                case .networkCache:
                    URLSessionTransport.responseCache?.removeAllCachedResponses()
                    try await waitUntilSettled(locations.networkCache, clock: clock)
                case .temporaryFiles:
                    guard let launchDate else { return }
                    // 前の起動のフォルダーが空になれば消すので、このプロセスがそのフォルダーを作ってからファイルを置くまでの間に消すと、置けずに失敗する。
                    // 置く側はどれも置く直前にフォルダーを作るので、重なるのは消すのと同じ瞬間に添付やダウンロードを始めたときだけで、その操作を失敗として知らせる。
                    // 置いたあとのファイルは、空のときだけ消すので消えない。
                    try await removeTemporaryFiles(in: locations.temporary, addedBefore: launchDate)
                case .inAppSafari:
                    await SFSafariViewController.DataStore.default.clearWebsiteData()
                case .discomfortReports:
                    try discomfortReports.removeAll()
                case .settings, .sharedMedia, .other:
                    preconditionFailure("消せない項目を消そうとした")
                }
            },
            mediaFiles: .app(mediaFiles),
            mediaPrefetch: .app(mediaPrefetchFiles)
        )
    }

    @concurrent
    private static func measure(_ locations: StorageLocations, launchDate: Date?) async -> StorageBreakdown {
        StorageBreakdown.measure(locations, launchDate: launchDate)
    }

    /// 消し終えるまで待つ。URLCacheは`removeAllCachedResponses()`から戻ったあともファイルを裏で消し続け、終わったことを知らせるAPIもない。
    /// すぐに測り直すと、消す前の大きさを出してしまう。iOS 27のシミュレーターでは、データベースが縮んで大きさが0.1秒以上止まったあとに、
    /// 応答の本文を置く`fsCachedData`がまとめて消えた。そのため、`fsCachedData`が空になり、そのうえで0.1秒おいて大きさが変わらなくなるまで待つ。
    /// 測るのにかかった時間も含めて5秒たっても終わらないときは、そこで測り直す。
    @concurrent
    private static func waitUntilSettled(_ files: [URL], clock: any Clock<Duration>) async throws {
        let size = { files.reduce(0) { $0 + StorageUsage.allocatedSize(of: $1) } }
        let bodies = files.filter { $0.lastPathComponent == "fsCachedData" }
        let elapsed = stopwatch(on: clock)
        var last = size()
        while elapsed() < .seconds(5) {
            try await clock.sleep(for: .milliseconds(100))
            let current = size()
            defer { last = current }
            let bodiesRemoved = bodies.allSatisfy { StorageUsage.allocatedSize(of: $0) == 0 }
            if bodiesRemoved && current == last { return }
        }
    }

    @concurrent
    private static func removeTemporaryFiles(in directory: URL, addedBefore date: Date) async throws {
        try StorageUsage.removeItems(in: directory, addedBefore: date)
    }
}
