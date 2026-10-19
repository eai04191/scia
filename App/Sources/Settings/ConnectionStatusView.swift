import SciaCore
import SwiftUI

/// 接続しているサーバーと、通信の状態を確かめる画面。うまく読み込めないときに、使う人が原因の見当を付けたり、報告に添えたりするために使う。
struct ConnectionStatusView: View {
    let instance: URL
    let diagnostics: ConnectionDiagnostics
    @State private var status: ConnectionDiagnostics.Status?

    var body: some View {
        List {
            Section("サーバー") {
                LabeledContent("アドレス", value: instance.host() ?? instance.absoluteString)
                LabeledContent("バージョン", value: diagnostics.serverVersion ?? "読み込めていません")
            }
            Section("ストリーミング") {
                LabeledContent("接続", value: Self.text(diagnostics.streaming))
            }
            Section {
                if diagnostics.streamingSubscriptions.isEmpty {
                    Text("ありません")
                } else {
                    ForEach(diagnostics.streamingSubscriptions, id: \.self) { subscription in
                        LabeledContent(Self.name(of: subscription), value: subscription.stream)
                    }
                }
            } header: {
                Text("購読しているストリーム")
            } footer: {
                Text("1本の接続で、これらの更新をまとめて受け取ります。")
            }
            if let status {
                Section("レート制限") {
                    if let pausedUntil = status.pausedUntil {
                        LabeledContent("自動の読み込みを控えています", value: "\(pausedUntil.formatted(date: .omitted, time: .standard))まで")
                    } else {
                        Text("制限されていません")
                    }
                }
                Section {
                    if status.disabledFeatures.isEmpty && unprocessableFormats.isEmpty {
                        Text("ありません")
                    } else {
                        ForEach(status.disabledFeatures, id: \.feature) { disabled in
                            LabeledContent(Self.name(of: disabled.feature), value: "HTTP \(disabled.statusCode)・\(disabled.date.formatted(date: .omitted, time: .shortened))")
                        }
                        ForEach(unprocessableFormats, id: \.mimeType) { entry in
                            LabeledContent(Self.name(ofImageType: entry.mimeType), value: "JPEGで送っています・\(entry.serverVersion.isEmpty ? "版が不明" : entry.serverVersion)")
                        }
                    }
                } header: {
                    Text("使っていない機能")
                } footer: {
                    Text("このサーバーにないと分かった機能は、アプリを起動し直すまで使いません。起動し直すと、もう一度試します。サーバーが処理できなかった画像の形式は、起動し直しても使いません。サーバーの版が変わると、もう一度試します。")
                }
                Section("最近のエラー") {
                    if status.recentFailures.isEmpty {
                        Text("ありません")
                    } else {
                        ForEach(status.recentFailures) { failure in
                            FailureRow(failure: failure)
                        }
                    }
                }
                Section {
                    LabeledContent("読めなかった項目", value: "\(status.droppedCount)件")
                } footer: {
                    Text("アプリを起動してから、サーバーから届いた内容のうち読めなかった投稿や通知などの数です。")
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("接続の状態")
        .task {
            // 開いている間も状態は変わるため、読み直し続ける。
            while !Task.isCancelled {
                status = await diagnostics.status()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func text(_ state: ConnectionDiagnostics.StreamingState?) -> String {
        switch state {
        case .connected: "接続中"
        case .connecting: "接続待ち"
        case .polling: "切断中・ポーリング中"
        case .stopped: "停止中"
        case .loginRequired: "停止中（ログインが必要）"
        case nil: "未接続"
        }
    }

    private static func name(of subscription: StreamingSubscription) -> String {
        switch subscription {
        case .user: "ホームと通知"
        default: subscription.stream
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
        case .preferences: "アカウントの設定（公開範囲の既定値など）"
        case .instanceV2: "サーバーの設定（v2）"
        case .multipleStatuses: "リンクカードの取り直し"
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
