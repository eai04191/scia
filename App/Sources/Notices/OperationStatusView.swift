import SciaCore
import SwiftUI
import UIKit

/// 「操作の状況」の画面。処理の途中と、消えたチップの失敗をあとから確かめる。決まりはdocs/notices.mdの「操作の状況」にある。
/// タブの「通知」（Mastodonの通知）と紛れないよう、「通知」という言葉は使わない。
struct OperationStatusView: View {
    let notices: OperationStatus
    /// 行の投稿を開く。「操作の状況」を閉じてから開くのは呼ぶ側で行う。
    let onOpen: (OperationStatus.Subject) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(OperationStatusTexts.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(OperationStatusTexts.done) { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if notices.activities.isEmpty && notices.failures.isEmpty {
            ContentUnavailableView {
                Label(OperationStatusTexts.empty, systemImage: "checkmark.circle")
            } description: {
                Text(OperationStatusTexts.emptyDescription)
            }
        } else {
            List {
                if !notices.activities.isEmpty {
                    Section(OperationStatusTexts.activitiesHeader) {
                        ForEach(notices.activities) { activity in
                            ActivityRow(activity: activity) { notices.stop(activity.id) }
                        }
                    }
                }
                Section {
                    if notices.failures.isEmpty {
                        Text(OperationStatusTexts.noFailures)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notices.failures) { failure in
                        FailureRow(failure: failure, time: notices.timeText(of: failure), accessibilityTime: notices.accessibilityTimeText(of: failure), onOpen: onOpen)
                            .swipeActions {
                                Button(OperationStatusTexts.delete, role: .destructive) {
                                    withAnimation { notices.removeFailure(failure.id) }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(OperationStatusTexts.failuresHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !notices.failures.isEmpty {
                            Button(OperationStatusTexts.clearFailures) {
                                withAnimation { notices.removeAllFailures() }
                            }
                            .font(.subheadline)
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text(OperationStatusTexts.failuresFooter(limit: OperationStatus.failureLimit))
                }
            }
            .topEdgeEffectHiddenOnMac()
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                notices.dayDidChange()
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
            ProgressRingStopButton(activity: activity, onStop: onStop)
        }
    }
}

/// App Storeのように、進み具合の輪と止める操作を1つにする。止められるなら中に停止の四角を置き、選択すると確かめずに止める。
/// 確かめないのは、行ごとに置いた44pt四方のボタンで、誤って選択しにくいため。
/// 進み具合が分からないときと、落とし終えて写真に足している間は、満ちた輪では済んだように見えるため、欠けた輪を回す。
private struct ProgressRingStopButton: View {
    let activity: OperationStatus.Activity
    let onStop: () -> Void

    private static let diameter: CGFloat = 28
    private static let lineWidth: CGFloat = 2.5

    var body: some View {
        if activity.isStoppable {
            Button(action: onStop) {
                ring
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.tint)
                            .frame(width: 9, height: 9)
                    }
                    // 輪は小さいため、ヒット領域は44ptにする。
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OperationStatusTexts.stop)
        } else {
            ring
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var ring: some View {
        let track = Circle().stroke(.quaternary, lineWidth: Self.lineWidth)
        if let fraction = activity.fraction, fraction < 1 {
            track
                .overlay {
                    Circle()
                        .trim(from: 0, to: max(fraction, 0.02))
                        .stroke(.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                }
                .frame(width: Self.diameter, height: Self.diameter)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                track
                    .overlay {
                        Circle()
                            .trim(from: 0, to: 0.25)
                            .stroke(.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360))
                    }
            }
            .frame(width: Self.diameter, height: Self.diameter)
        }
    }
}

private struct FailureRow: View {
    let failure: OperationStatus.Failure
    let time: String
    let accessibilityTime: String
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
            .accessibilityHint(OperationStatusTexts.openStatusHint)
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
                Text(time)
                    .accessibilityLabel(accessibilityTime)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            FailureReason(reason: failure.reason)
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

/// どの投稿の操作かを、投稿者と本文の冒頭で示す。
/// 名前は1行で切り、本文は次の行から出す。つなげて出すと、長い名前が行を使い切って本文が見えなくなるため。
private struct SubjectLine: View {
    let subject: OperationStatus.Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subject.authorName)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(subject.excerpt)
                .lineLimit(2)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
