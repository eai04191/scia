import SafariServices
import SciaCore
import SwiftUI

/// アプリが端末で使っている大きさを置き場所ごとに見せ、消してよいものを消す画面。
struct StorageView: View {
    /// 測る処理と消す処理。部品カタログでは、ファイルに触れずに状態を作るために差し替える。
    struct Actions {
        var measure: @Sendable () async -> StorageBreakdown
        var remove: @Sendable (StorageBreakdown.Category) async throws -> Void
        /// メディアのキャッシュの中身を並べる画面の処理。
        var mediaFiles: MediaCacheView.Actions
    }

    let actions: Actions
    @State private var breakdown: StorageBreakdown?
    /// 消している途中の項目。消し終えて測り直すまで、ほかの項目も消せないようにする。
    @State private var removing: StorageBreakdown.Category?
    @State private var removeError: String?
    /// 消す前に確かめている項目。キャッシュと違い、消すと戻らないものがある項目だけ確かめる。
    @State private var confirming: StorageBreakdown.Category?

    /// - Parameters:
    ///   - removing: 消している途中の項目。部品カタログで、消している途中の見た目を作るために渡す。
    ///   - removeError: 消せなかったときの説明。部品カタログで、失敗の見た目を作るために渡す。
    init(actions: Actions = .app, removing: StorageBreakdown.Category? = nil, removeError: String? = nil) {
        self.actions = actions
        _removing = State(initialValue: removing)
        _removeError = State(initialValue: removeError)
    }

    /// 消せる項目。ほかの項目は、使う人のデータか、なくなるとアプリが動かないもの。
    static let removableCategories: [StorageBreakdown.Category] = [.mediaFiles, .networkCache, .temporaryFiles, .inAppSafari, .discomfortReports]

    var body: some View {
        List {
            if let breakdown {
                Section {
                    ForEach(breakdown.items, id: \.category) { item in
                        if item.category == .mediaFiles {
                            // 中身を見返して、共有や保存をできるようにする。
                            NavigationLink {
                                MediaCacheView(actions: actions.mediaFiles)
                            } label: {
                                LabeledContent(Self.name(of: item.category), value: Self.text(item.bytes))
                            }
                        } else {
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
                    ForEach(Self.removableCategories, id: \.self) { category in
                        removeButton(category, bytes: breakdown.item(category).map(\.removableBytes) ?? 0)
                    }
                } footer: {
                    if let removeError {
                        Text("消せませんでした。\(removeError)")
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
        .task {
            breakdown = await actions.measure()
        }
        .confirmationDialog(
            confirming.map { "\(Self.name(of: $0))を消しますか？" } ?? "",
            isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
            titleVisibility: .visible,
            presenting: confirming
        ) { category in
            Button("消す", role: .destructive) { remove(category) }
        } message: { category in
            Text(Self.confirmationMessage(for: category) ?? "")
        }
    }

    /// `bytes`がnilなら、測れないだけで消せるものがあるかもしれないので、押せるままにする。
    private func removeButton(_ category: StorageBreakdown.Category, bytes: Int64?) -> some View {
        Button {
            if Self.confirmationMessage(for: category) != nil {
                confirming = category
            } else {
                remove(category)
            }
        } label: {
            HStack {
                Text("\(Self.name(of: category))を消す")
                Spacer()
                if removing == category {
                    ProgressView()
                } else {
                    Text(Self.text(bytes))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(removing != nil || bytes == 0)
    }

    private func remove(_ category: StorageBreakdown.Category) {
        removing = category
        removeError = nil
        Task {
            do {
                try await actions.remove(category)
            } catch {
                removeError = ErrorPresentation(error).text
            }
            breakdown = await actions.measure()
            removing = nil
        }
    }

    /// 消す前に確かめる項目の説明。確かめずに消す項目ではnil。
    static func confirmationMessage(for category: StorageBreakdown.Category) -> String? {
        switch category {
        case .inAppSafari: "アプリ内のSafariで開いたサイトのキャッシュとCookieを消します。サイトからログアウトします。"
        case .discomfortReports: "保存した違和感レポートを全部消します。消したレポートは戻せません。"
        case .mediaFiles, .networkCache, .temporaryFiles, .settings, .sharedMedia, .other: nil
        }
    }

    static func name(of category: StorageBreakdown.Category) -> String {
        switch category {
        case .mediaFiles: "メディアのキャッシュ"
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
            mediaFiles: [AppDependencies.mediaFiles.directory, AppDependencies.mediaPrefetchFiles.directory],
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
            mediaFiles: .app
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
