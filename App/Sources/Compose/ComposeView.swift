import SciaCore
import SwiftUI

/// 投稿欄を広げた画面。タブバーの上の入力欄と同じ下書きを編集し、閉じても下書きは残す。
struct ComposeView: View {
    @Bindable var model: ComposeModel
    let onClose: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field {
        case text
        case spoiler
    }

    var body: some View {
        NavigationStack {
            Form {
                if let replyTo = model.replyTo?.displayed {
                    Section("返信先") {
                        VStack(alignment: .leading, spacing: 4) {
                            RichTextLabel(numberOfLines: 1) {
                                RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline).bold, textColor: .label, emojiImages: AppDependencies.emojiImages)
                                    .render(.plain(replyTo.account.displayNameOrUsername, emojis: replyTo.account.emojis))
                            }
                            RichTextLabel(numberOfLines: 3) {
                                RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .secondaryLabel, emojiImages: AppDependencies.emojiImages)
                                    .render(replyTo.spoilerText.isEmpty ? .status(replyTo) : .plain(replyTo.spoilerText, emojis: replyTo.emojis))
                            }
                        }
                    }
                }
                if model.showsSpoiler {
                    Section {
                        TextField("注意書き", text: $model.spoilerText, axis: .vertical)
                            .focused($focusedField, equals: .spoiler)
                    }
                }
                if !model.attachments.isEmpty {
                    Section {
                        attachments
                    }
                }
                Section {
                    TextField("いまどうしてる？", text: $model.text, axis: .vertical)
                        .lineLimit(6...)
                        .focused($focusedField, equals: .text)
                }
            }
            // ツールバーの下端はキーボードに隠れるため、キーボードの高さを含む下端のsafe areaに置き、キーボードの上に付いて動くようにする。
            .safeAreaInset(edge: .bottom) { composeBar }
            .navigationTitle(model.replyTo == nil ? "投稿" : "返信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .disabled(model.isPosting)
        }
        .onAppear { focusedField = .text }
        .alert("投稿できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// 添付したメディアのサムネイル。メディアを選んだり外したりするのは、タブバーの上の投稿欄で行う。
    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    let size = ComposeAttachmentStrip.itemSize
                    ZStack {
                        Color(uiColor: .secondarySystemFill)
                        if let thumbnail = model.localMedia[attachment.id]?.thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        }
                        switch attachment.state {
                        case .uploading, .processing:
                            Color.black.opacity(0.35)
                            ProgressView().tint(.white)
                        case .uploaded:
                            EmptyView()
                        case .failed:
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white, .red)
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: MediaGridView.cornerRadius, style: .continuous))
                }
            }
        }
    }

    /// 公開範囲、注意書き、残り文字数。
    private var composeBar: some View {
        GlassEffectContainer {
            HStack {
                HStack(spacing: 20) {
                    Menu {
                        Picker("公開範囲", selection: Binding(get: { model.visibility }, set: { model.choose($0) })) {
                            ForEach(VisibilityOption.choices, id: \.visibility) { option in
                                Label(option.title, systemImage: option.symbolName).tag(option.visibility)
                            }
                        }
                    } label: {
                        let option = VisibilityOption(model.visibility)
                        Label(option.title, systemImage: option.symbolName)
                    }
                    Button {
                        model.showsSpoiler.toggle()
                        focusedField = model.showsSpoiler ? .spoiler : .text
                    } label: {
                        Label("注意書き", systemImage: model.showsSpoiler ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .tint(.primary)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                Spacer()
                Text("\(model.remainingCharacters)")
                    .monospacedDigit()
                    .foregroundStyle(model.remainingCharacters < 0 ? .red : .secondary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .glassEffect(in: .capsule)
                    .accessibilityLabel("残り\(model.remainingCharacters)文字")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("閉じる", role: .close) { onClose() }
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isPosting {
                ProgressView()
            } else {
                Button("投稿") { Task { await model.submit() } }
                    .disabled(!model.canPost)
            }
        }
    }
}

/// 公開範囲の選択肢の見た目。
struct VisibilityOption {
    let visibility: Status.Visibility
    let title: String
    let symbolName: String

    init(_ visibility: Status.Visibility) {
        self.visibility = visibility
        (title, symbolName) = switch visibility {
        case .public: ("公開", "globe")
        case .unlisted: ("ひかえめな公開", "moon")
        case .private: ("フォロワーのみ", "lock")
        case .direct: ("メンションした相手のみ", "at")
        case .other(let rawValue): (rawValue, "questionmark.circle")
        }
    }

    static let choices: [VisibilityOption] = [.public, .unlisted, .private, .direct].map(VisibilityOption.init)
}
