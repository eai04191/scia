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
    @State private var removing: RemoveTarget?
    @State private var removeError: ErrorPresentation?
    /// 消す前に確かめているボタン。キャッシュと違い、消すと困ることがあるものだけ確かめる。
    @State private var confirming: RemoveTarget?

    /// - Parameters:
    ///   - removing: 消している途中のボタン。部品カタログで、消している途中の見た目を作るために渡す。
    ///   - removeError: 消せなかったときの説明。部品カタログで、失敗の見た目を作るために渡す。
    init(actions: Actions = .app, removing: RemoveTarget? = nil, removeError: ErrorPresentation? = nil) {
        self.actions = actions
        _removing = State(initialValue: removing)
        _removeError = State(initialValue: removeError)
    }

    /// 消すボタン。空き容量を増やすためのボタンなので、消してもまた見れば読み直すものは、1つのボタンでまとめて消す。
    /// 消せない項目は、使う人のデータか、なくなるとアプリが動かないもの。
    enum RemoveTarget: CaseIterable {
        /// 消しても、また見れば読み直すもの。
        case caches
        /// 消すとサイトからログアウトするので、キャッシュと分ける。
        case inAppSafari
        /// 開発のための仕組みで、消すと戻らないので、キャッシュと分ける。
        case discomfortReports

        var categories: [StorageBreakdown.Category] {
            switch self {
            case .caches: [.mediaFiles, .mediaPrefetch, .networkCache, .temporaryFiles]
            case .inAppSafari: [.inAppSafari]
            case .discomfortReports: [.discomfortReports]
            }
        }

        var name: String {
            switch self {
            case .caches: "キャッシュ"
            case .inAppSafari: StorageView.name(of: .inAppSafari)
            case .discomfortReports: StorageView.name(of: .discomfortReports)
            }
        }

        /// 消す前に確かめるときの説明。確かめずに消すボタンではnil。
        var confirmationMessage: String? {
            switch self {
            case .caches: nil
            case .inAppSafari: "アプリ内のSafariで開いたサイトのキャッシュとCookieを消します。サイトからログアウトします。"
            case .discomfortReports: "保存した違和感レポートを全部消します。消したレポートは戻せません。"
            }
        }

        /// 消せる大きさ。測れない項目が1つでもあればnilにして、消せるものがあるかもしれないので押せるままにする。
        func removableBytes(in breakdown: StorageBreakdown) -> Int64? {
            categories.reduce(Int64(0)) { sum, category in
                guard let sum, let bytes = breakdown.item(category).map(\.removableBytes) ?? 0 else { return nil }
                return sum + bytes
            }
        }
    }

    /// 内訳と消すボタンに出すか。違和感レポートは開発のための仕組みなので、残っているときだけ出す。測れなかったときは、残っているかもしれないので出す。
    static func isShown(_ category: StorageBreakdown.Category, bytes: Int64?) -> Bool {
        category != .discomfortReports || bytes != 0
    }

    var body: some View {
        List {
            if let breakdown {
                Section {
                    ForEach(breakdown.items.filter { Self.isShown($0.category, bytes: $0.bytes) }, id: \.category) { item in
                        switch item.category {
                        case .mediaFiles:
                            mediaCacheRows(viewed: item, prefetched: breakdown.item(.mediaPrefetch))
                        case .mediaPrefetch:
                            // メディアのキャッシュの下の段に並べる。
                            EmptyView()
                        default:
                            LabeledContent(Self.name(of: item.category), value: Self.text(item.bytes))
                        }
                    }
                    LabeledContent {
                        Text(Self.text(breakdown.dataBytes))
                    } label: {
                        Text("合計").bold()
                    }
                } header: {
                    Text("書類とデータ")
                } footer: {
                    if breakdown.hasUnmeasuredItems {
                        Text("「不明」の項目は合計に入っていません。")
                    }
                }
                Section {
                    ForEach(RemoveTarget.allCases.filter { target in target.categories.allSatisfy { Self.isShown($0, bytes: breakdown.item($0)?.bytes) } }, id: \.self) { target in
                        removeButton(target, bytes: target.removableBytes(in: breakdown))
                    }
                } footer: {
                    if let removeError {
                        FailureReason(reason: removeError, lead: "消せませんでした。")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    LabeledContent("アプリ本体", value: Self.text(breakdown.appBytes))
                } footer: {
                    Text("このiPhoneに入っているアプリのファイルを足した大きさです。iPhoneの設定の「Appのサイズ」とは数え方が違い、ずれることがあります。")
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView("測っています")
                    Spacer()
                }
            }
        }
        .navigationTitle("ストレージ")
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) {
            breakdown = await actions.measure()
        }
        .confirmationDialog(
            confirming.map { "\($0.name)を消しますか？" } ?? "",
            isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
            titleVisibility: .visible,
            presenting: confirming
        ) { target in
            Button("消す", role: .destructive) { remove(target) }
        } message: { target in
            Text(target.confirmationMessage ?? "")
        }
    }

    /// メディアのキャッシュを、合計の行の下に、表示済みと先読みの2段に分けて並べる。
    /// 置き場の違う2つを1つの項目として数えつつ、それぞれの大きさと中身を見られるようにする（docs/image-loading.md）。
    @ViewBuilder
    private func mediaCacheRows(viewed: StorageBreakdown.Item, prefetched: StorageBreakdown.Item?) -> some View {
        let total: Int64? = if let viewedBytes = viewed.bytes, let prefetchedBytes = prefetched?.bytes { viewedBytes + prefetchedBytes } else { nil }
        LabeledContent(Self.mediaCacheName, value: Self.text(total))
        // 中身を見返して、共有や保存をできるようにする。
        NavigationLink {
            MediaCacheView(category: .mediaFiles, actions: actions.mediaFiles)
        } label: {
            LabeledContent("表示済み", value: Self.text(viewed.bytes))
                .padding(.leading, Self.subrowIndent)
        }
        NavigationLink {
            MediaCacheView(category: .mediaPrefetch, actions: actions.mediaPrefetch)
        } label: {
            LabeledContent("先読み", value: Self.text(prefetched?.bytes))
                .padding(.leading, Self.subrowIndent)
        }
    }

    /// 表示済みと先読みを合わせた、メディアのキャッシュの名前。
    static let mediaCacheName = "メディアのキャッシュ"
    /// メディアのキャッシュの下の段を、合計の行より下げる幅。
    private static let subrowIndent: CGFloat = 16

    /// 消せる大きさは、上の内訳の値と同じなので出さない。値を並べると、内訳と同じ押せない行の形になるため。
    /// `bytes`がnilなら、測れないだけで消せるものがあるかもしれないので、押せるままにする。
    private func removeButton(_ target: RemoveTarget, bytes: Int64?) -> some View {
        Button {
            if target.confirmationMessage != nil {
                confirming = target
            } else {
                remove(target)
            }
        } label: {
            HStack {
                Text("\(target.name)を消す")
                Spacer()
                if removing == target {
                    ProgressView()
                }
            }
        }
        .disabled(removing != nil || bytes == 0)
    }

    /// 項目を順に消す。1つ消せなくても残りは消し、最初に消せなかった理由を出す。
    private func remove(_ target: RemoveTarget) {
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

    nonisolated static func name(of category: StorageBreakdown.Category) -> String {
        switch category {
        case .mediaFiles: "表示済みのメディア"
        case .mediaPrefetch: "先読みしたメディア"
        case .networkCache: "通信のキャッシュ"
        case .temporaryFiles: "一時ファイル"
        case .inAppSafari: "アプリ内のSafariのデータ"
        case .discomfortReports: "違和感レポート"
        case .settings: "設定"
        case .sharedMedia: "共有から受け取り中のメディア"
        case .other: "その他"
        }
    }

    /// iPhoneの設定と同じく、1000バイトを1KBとして、大きさに合った単位で書く。測れないときは「不明」。
    static func text(_ bytes: Int64?) -> String {
        bytes?.formatted(.byteCount(style: .file)) ?? "不明"
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
        return Self(
            measure: { await measure(locations, launchDate: launchDate) },
            remove: { category in
                switch category {
                case .mediaFiles:
                    try await mediaFiles.removeCachedFiles()
                case .mediaPrefetch:
                    try await mediaPrefetchFiles.removeCachedFiles()
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
