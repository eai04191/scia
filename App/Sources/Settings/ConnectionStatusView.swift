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
                LabeledContent(SettingsTexts.Connection.server, value: instance.host() ?? instance.absoluteString)
                LabeledContent(SettingsTexts.Connection.version, value: diagnostics.serverVersion ?? SettingsTexts.Connection.versionUnknown)
            }
            Section {
                LabeledContent(SettingsTexts.Connection.streaming) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ConnectionDiagnostics.StreamingState.title(of: diagnostics.streaming))
                        if let note = ConnectionDiagnostics.StreamingState.note(of: diagnostics.streaming) {
                            Text(note)
                                .font(.footnote)
                        }
                    }
                }
                if !diagnostics.streamingSubscriptions.isEmpty {
                    NavigationLink(value: SettingsPage.connectionTimelines) {
                        LabeledContent(SettingsPage.connectionTimelines.title, value: "\(diagnostics.streamingSubscriptions.count)")
                    }
                }
            }
            if let status {
                Section {
                    LabeledContent(SettingsTexts.Connection.rateLimit, value: SettingsTexts.Connection.rateLimitValue(pausedUntil: status.pausedUntil))
                } footer: {
                    if status.pausedUntil != nil {
                        Text(SettingsTexts.Connection.rateLimitFooter)
                    }
                }
                if !status.disabledFeatures.isEmpty || !unprocessableFormats.isEmpty {
                    Section(SettingsTexts.Connection.disabledFeatures) {
                        ForEach(status.disabledFeatures, id: \.feature) { disabled in
                            LabeledContent(disabled.feature.title, value: SettingsTexts.Connection.disabledFeatureValue(statusCode: disabled.statusCode, date: disabled.date))
                        }
                        ForEach(unprocessableFormats, id: \.mimeType) { entry in
                            LabeledContent(SettingsTexts.Connection.imageTypeTitle(mimeType: entry.mimeType), value: SettingsTexts.Connection.unprocessableFormatValue(serverVersion: entry.serverVersion))
                        }
                    }
                }
                if !status.recentFailures.isEmpty {
                    Section(SettingsTexts.Connection.recentFailures) {
                        ForEach(status.recentFailures) { failure in
                            FailureRow(failure: failure)
                        }
                    }
                }
                Section {
                    LabeledContent(SettingsTexts.Connection.dropped, value: SettingsTexts.count(status.droppedCount))
                } footer: {
                    Text(SettingsTexts.Connection.droppedFooter)
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.connection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) {
            // 開いている間も状態は変わるため、読み直し続ける。
            while !Task.isCancelled {
                status = await diagnostics.status()
                try? await clock.sleep(for: .seconds(1))
            }
        }
    }

    /// 今の版のサーバーでは送らないと覚えている形式。
    private var unprocessableFormats: [UnprocessableMediaFormats.Entry] {
        let version = diagnostics.serverVersion ?? ""
        return diagnostics.mediaFormats.entries.filter { $0.serverVersion == version }
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
            Text(SettingsTexts.Connection.failureDetail(date: failure.date, kind: failure.kindDescription))
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
                Text(subscription.title(listTitles: listTitles))
            } label: {
                Text(streamValue(of: subscription))
                    .font(.body.monospaced())
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.connectionTimelines.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// サーバーへ申し込むストリームの値。
    private func streamValue(of subscription: StreamingSubscription) -> String {
        [subscription.stream, subscription.list ?? subscription.tag].compactMap(\.self).joined(separator: ":")
    }
}
