import SciaCore
import SwiftUI

/// 接続しているサーバーと、通信の状態を確かめる画面。うまく読み込めないときに、使う人が原因の見当を付けたり、報告に添えたりするために使う。
struct ConnectionStatusView: View {
    let instance: URL
    let diagnostics: ConnectionDiagnostics
    @State private var status: ConnectionDiagnostics.Status?
    /// 読み直す間隔を数える時計。
    var clock: any Clock<Duration> = AppDependencies.clock

    var body: some View {
        List {
            Section {
                LabeledContent("サーバー", value: instance.host() ?? instance.absoluteString)
                LabeledContent("バージョン", value: diagnostics.serverVersion ?? "読み込めていません")
            }
            Section {
                LabeledContent("ストリーミング") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.text(diagnostics.streaming))
                        if let note = Self.note(diagnostics.streaming) {
                            Text(note)
                                .font(.footnote)
                        }
                    }
                }
                if !diagnostics.streamingSubscriptions.isEmpty {
                    NavigationLink(value: SettingsPage.connectionTimelines) {
                        LabeledContent("受信中のタイムライン", value: "\(diagnostics.streamingSubscriptions.count)")
                    }
                }
            }
            if let status {
                Section {
                    LabeledContent("レート制限", value: status.pausedUntil.map { "\($0.formatted(date: .omitted, time: .standard))まで" } ?? "なし")
                } footer: {
                    if status.pausedUntil != nil {
                        Text("自動の読み込みを控えています。")
                    }
                }
                if !status.disabledFeatures.isEmpty || !unprocessableFormats.isEmpty {
                    Section("使っていない機能") {
                        ForEach(status.disabledFeatures, id: \.feature) { disabled in
                            LabeledContent(Self.name(of: disabled.feature), value: "HTTP \(disabled.statusCode)・\(disabled.date.formatted(date: .omitted, time: .shortened))")
                        }
                        ForEach(unprocessableFormats, id: \.mimeType) { entry in
                            LabeledContent(Self.name(ofImageType: entry.mimeType), value: "JPEGで送っています・\(entry.serverVersion.isEmpty ? "版が不明" : entry.serverVersion)")
                        }
                    }
                }
                if !status.recentFailures.isEmpty {
                    Section("最近のエラー") {
                        ForEach(status.recentFailures) { failure in
                            FailureRow(failure: failure)
                        }
                    }
                }
                Section {
                    LabeledContent("読めなかった項目", value: "\(status.droppedCount)件")
                } footer: {
                    Text("アプリを起動してからサーバーから届いた内容のうち読めなかった投稿や通知などの数です。")
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("接続の状態")
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) {
            // 開いている間も状態は変わるため、読み直し続ける。
            while !Task.isCancelled {
                status = await diagnostics.status()
                try? await clock.sleep(for: .seconds(1))
            }
        }
    }

    private static func text(_ state: ConnectionDiagnostics.StreamingState?) -> String {
        switch state {
        case .connected: "接続済み"
        case .connecting, .polling: "接続中"
        case .stopped, .loginRequired, nil: "未接続"
        }
    }

    private static func note(_ state: ConnectionDiagnostics.StreamingState?) -> String? {
        switch state {
        case .polling: "ポーリング中"
        case .loginRequired: "ログインが必要"
        case .connected, .connecting, .stopped, nil: nil
        }
    }

    /// 今の版のサーバーでは送らないと覚えている形式。
    private var unprocessableFormats: [UnprocessableMediaFormats.Entry] {
        let version = diagnostics.serverVersion ?? ""
        return diagnostics.mediaFormats.entries.filter { $0.serverVersion == version }
    }

    private static func name(ofImageType mimeType: String) -> String {
        let format = switch mimeType {
        case "image/heic": "HEIC"
        case "image/heif": "HEIF"
        case "image/avif": "AVIF"
        default: mimeType
        }
        return "\(format)の画像を送る"
    }

    private static func name(of feature: OptionalFeature) -> String {
        switch feature {
        case .markers: "既読位置の保存"
        case .preferences: "アカウントの設定（公開範囲のデフォルトなど）"
        case .instanceV2: "サーバーの設定（v2）"
        case .multipleStatuses: "リンクカードの取り直し"
        case .multipleAccounts: "メンションされたユーザーのアイコン"
        case .groupedNotifications: "通知のまとめ表示"
        case .notificationFilter: "保留中の通知"
        }
    }
}

private struct FailureRow: View {
    let failure: RequestFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(failure.method) \(failure.path)")
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(failure.date.formatted(date: .omitted, time: .standard))・\(failure.kindDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let body = failure.body {
                // デバッグ版でだけ残す応答の本文。
                Text(body)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

/// ストリーミングで受信しているタイムラインの一覧。
struct StreamingTimelinesView: View {
    let diagnostics: ConnectionDiagnostics
    /// リストのIDから、タブの並びに保存したリストの名前を引く。並びにないリストは名前を出さない。
    let listTitles: [String: String]

    var body: some View {
        List(diagnostics.streamingSubscriptions, id: \.self) { subscription in
            LabeledContent {
                Text(name(of: subscription))
            } label: {
                Text(streamValue(of: subscription))
                    .font(.body.monospaced())
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("受信中のタイムライン")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// サーバーへ申し込むストリームの値。
    private func streamValue(of subscription: StreamingSubscription) -> String {
        [subscription.stream, subscription.list ?? subscription.tag].compactMap(\.self).joined(separator: ":")
    }

    /// タブの名前にそろえる。
    private func name(of subscription: StreamingSubscription) -> String {
        switch subscription.stream {
        case "user": "ホームと通知"
        case "public:local": "ローカル"
        case "public": "連合"
        case "list": subscription.list.flatMap { listTitles[$0] }.map { "リスト“\($0)”" } ?? "リスト"
        case "hashtag": subscription.tag.map { "#\($0)" } ?? "ハッシュタグ"
        default: subscription.stream
        }
    }
}
