import SciaCore
import SwiftUI
import UIKit

/// 「操作の状況」の一覧。処理の途中と、消えたチップの失敗をあとから確かめる。決まりはdocs/notices.mdの「操作の状況」にある。
/// タブの「通知」（Mastodonの通知）と紛れないよう、「通知」という言葉は使わない。
struct OperationStatusView: View {
    let notices: OperationStatus
    /// 行の投稿を開く。一覧を閉じてから開くのは呼ぶ側で行う。
    let onOpen: (OperationStatus.Subject) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("操作の状況")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if notices.activities.isEmpty && notices.failures.isEmpty {
            ContentUnavailableView {
                Label("進行中の操作も失敗もありません", systemImage: "checkmark.circle")
            } description: {
                Text("保存のためのダウンロードと、お気に入りやブーストなどの失敗が並びます。失敗はアプリを終了するまで残ります。")
            }
        } else {
            List {
                if !notices.activities.isEmpty {
                    Section("進行中") {
                        ForEach(notices.activities) { activity in
                            ActivityRow(activity: activity) { notices.stop(activity.id) }
                        }
                    }
                }
                Section {
                    if notices.failures.isEmpty {
                        Text("失敗はありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notices.failures) { failure in
                        FailureRow(failure: failure, onOpen: onOpen)
                    }
                } header: {
                    Text("最近の失敗")
                } footer: {
                    Text("アプリを終了するまで、直近の\(OperationStatus.failureLimit)件を残します。")
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: OperationStatus.Activity
    /// 行から止める。止められないものでは出さない。
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let value = activity.value {
                        Text(value)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let subject = activity.subject {
                    SubjectLine(subject: subject)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if activity.isStoppable {
                // 確かめずに止める。行の中の小さなボタンで、押し間違えにくいため。
                Button("止める", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }
}

private struct FailureRow: View {
    let failure: OperationStatus.Failure
    let onOpen: (OperationStatus.Subject) -> Void

    var body: some View {
        if let subject = failure.subject {
            Button {
                onOpen(subject)
            } label: {
                HStack(spacing: 8) {
                    details
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("投稿を開きます。")
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(failure.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(failure.date, format: .dateTime.hour().minute())
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text(failure.reason.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if let subject = failure.subject {
                SubjectLine(subject: subject)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// どの投稿の知らせかを、投稿者と本文の冒頭で示す。
private struct SubjectLine: View {
    let subject: OperationStatus.Subject

    var body: some View {
        Text("\(Text(subject.authorName).fontWeight(.semibold))  \(subject.excerpt)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 3)
            }
    }
}

extension OperationStatusView {
    /// 下から半分の高さで開き、引き上げると広がるシートにする。
    @MainActor
    static func makeSheet(notices: OperationStatus, onOpen: @escaping (OperationStatus.Subject) -> Void) -> UIViewController {
        let controller = UIHostingController(rootView: OperationStatusView(notices: notices, onOpen: onOpen))
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return controller
    }
}
