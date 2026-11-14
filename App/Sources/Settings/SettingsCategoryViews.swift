import SciaCore
import SwiftUI
import UIKit

/// 設定のトップの画面の、分類の画面へ入る行のラベル。iPhoneの設定アプリと同じアイコンを名前に添える。
struct SettingsCategoryLabel: View {
    let title: String
    let systemImage: String
    /// 四角に敷くシステムカラー。
    let color: UIColor

    init(_ title: String, systemImage: String, color: UIColor) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(systemImage: systemImage, color: color)
        }
    }
}

/// iOS 27.2の設定アプリのアイコンと同じ描き方で、システムカラーを敷いた角丸の四角に白い記号を描く。値は、シミュレーターで設定アプリとSciaを撮り、画素を比べて合わせた。
struct SettingsIcon: View {
    let systemImage: String
    let color: UIColor
    /// 四角の一辺。文字の大きさに合わせて伸ばす。
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(systemName: systemImage)
            // 記号は四角の中に描く絵なので、四角の一辺から大きさを決める。一辺は文字の大きさに合わせて伸びる。
            // 設定アプリは記号ごとに太さも変えていて、大きさまで一致した3つのうち、歯車と砂時計はmedium、アクセシビリティはregularに近かった。
            // scialint:disable:next fixed_font_size
            .font(.system(size: glyphSize, weight: .medium))
            // Formの行のLabelは記号を大きく描くので、大きさを固定する。
            .imageScale(.medium)
            // 記号は、下へ行くほどわずかに下の色が透ける。
            .foregroundStyle(LinearGradient(colors: [.white, Color(uiColor: .dimmedWhiteText(alpha: 0.97))], startPoint: .top, endPoint: .bottom))
            // 記号の影は下にだけ落ち、上と横にはほとんど出ない。濃さは記号によって違い、歯車の歯の下はアクセシビリティの円の下より濃かったので、両方の差の合計が小さくなる値にした。
            .shadow(color: .black.opacity(0.12), radius: 0.6, y: 1)
            .frame(width: side, height: side)
            .background { tile }
    }

    private var glyphSize: CGFloat {
        Self.glyphPointSize(side: side, systemImage: systemImage)
    }

    /// 記号を描く大きさ。設定アプリの記号は、一辺の2/3の大きさで描いたものと、円の直径も線の太さも一致した（歯車とアクセシビリティ）。設定アプリで測った10個の記号のうち7個は、見た目の縦横の大きいほうが一辺の2/3に収まっていたので、2/3で描くとそれを超える記号（カメラ、写真など）は、収まるまで縮める。小さい記号は大きくしない。収まっていなかったのは、歯車、スタンバイ、一般の「フォント」の3つで、設定アプリが記号ごとに決めた大きさなので合わせていない。
    static func glyphPointSize(side: CGFloat, systemImage: String) -> CGFloat {
        let size = side * 2 / 3
        guard let ratio = visualExtentRatio(of: systemImage), ratio > 1 else { return size }
        return size / ratio
    }

    private static var extentRatios: [String: CGFloat] = [:]

    /// 記号を描いたときの、見た目の縦横の大きいほうの、描いた大きさに対する割合。`UIImage`の大きさは見た目より大きく出るので、描いた画素の範囲で測る。記号ごとに1回だけ描いて覚える。
    static func visualExtentRatio(of systemImage: String) -> CGFloat? {
        if let ratio = extentRatios[systemImage] { return ratio }
        let pointSize: CGFloat = 100
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = UIImage(systemName: systemImage, withConfiguration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let extent = drawn.cgImage.flatMap(opaqueExtent) else { return nil }
        let ratio = extent / pointSize
        extentRatios[systemImage] = ratio
        return ratio
    }

    /// 透明でない画素の範囲の、縦横の大きいほう（画素の数）。
    private static func opaqueExtent(of image: CGImage) -> CGFloat? {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drew = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGFloat(max(maxX - minX + 1, maxY - minY + 1))
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.265, style: .continuous)
        let base = Color(uiColor: color.resolvedColor(with: Self.tileTraits(contrast: contrast)))
        let hairline = 1 / displayScale
        return ZStack {
            shape.fill(base)
            // 上へ行くほど明るい。設定アプリの四角は、上の端で下の端の約1.09倍の値になり、色の割合は変わらない。同じ色を足して明るくする。
            shape.fill(base)
                .mask(LinearGradient(colors: [.white.opacity(0.085), .clear], startPoint: .top, endPoint: .bottom))
                .blendMode(.plusLighter)
            // フチは、上と下で明るく、横の真ん中では暗い。いちばん外の1画素が明るく、上ではその内側の1画素もわずかに明るい。
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.2),
                        .init(color: .black.opacity(0.065), location: 0.5),
                        .init(color: .clear, location: 0.8),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: hairline
            )
            shape.strokeBorder(Self.rim(top: 0.24, bottom: 0.18), lineWidth: hairline)
                .blendMode(.plusLighter)
            shape.strokeBorder(Self.rim(top: 0.045, bottom: 0.02), lineWidth: hairline * 2)
                .blendMode(.plusLighter)
        }
        .compositingGroup()
    }

    private static func rim(top: Double, bottom: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(top), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.7),
                .init(color: .white.opacity(bottom), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 四角の色は、ライトモードとダークモードで変えない。設定アプリの四角は、どちらのモードでもライトモードの版のシステムカラーで、「コントラストを上げる」ではライトモードの高コントラスト版になる。ダークモードの高コントラスト版は暗い背景との差を広げるために明るくなり、白い記号が見えにくくなる。
    private static func tileTraits(contrast: ColorSchemeContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
    }
}

/// 並びが決まっている設定の画面（表示、操作、作成、メディア、リンク先の読み込み）。何を、どの順で、どんな名前で並べるかは`SettingsPage.sections`にあり、ここは行の部品を選んで描く。
struct SettingsScreenForm: View {
    let page: SettingsPage
    @Bindable var settings: AppSettings
    /// 設定を閉じ、ホームの上でアプリ内のSafariの高さを選ぶシートを出す。
    var openInAppBrowserHeight: @MainActor () -> Void = {}

    var body: some View {
        Form {
            ForEach(sections, id: \.self) { section in
                if section.rows == [.item(.statusBarTicker)] {
                    StatusBarTickerSettingsSection(isOn: $settings.showsStatusBarTicker, isAvailable: StatusBarCutout.isAvailable)
                } else {
                    SettingsFormSection(header: section.header, footer: footer(of: section)) {
                        ForEach(section.rows, id: \.self) { row in
                            switch row {
                            case .page(let page): NavigationLink(page.rowTitle, value: page)
                            case .item(let item): itemRow(item)
                            }
                        }
                    }
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// このiOSで出せない行を除いた節。
    private var sections: [SettingsSection] {
        (page.sections ?? []).compactMap { section in
            var section = section
            section.rows.removeAll { !Self.isAvailable($0) }
            return section.rows.isEmpty ? nil : section
        }
    }

    private static func isAvailable(_ row: SettingsRow) -> Bool {
        guard row == .page(.autoTranslation) else { return true }
        if #available(iOS 26.4, *) { return true }
        return false
    }

    /// 節の下の説明。iOSの版や機種で決まる説明は、ここで足す。
    private func footer(of section: SettingsSection) -> String? {
        if section.rows.contains(.item(.accentColor)), settings.accentColor.obscuresSelectedTab {
            return SettingsTexts.Display.accentColorObscuresSelectedTab
        }
        return section.footer
    }

    @ViewBuilder
    private func itemRow(_ item: SettingsItem) -> some View {
        switch item {
        case .accentColor: AccentColorPicker(selection: $settings.accentColor)
        case .insertionMotion: choicePicker(item, selection: $settings.insertionMotion, title: \.title)
        case .statusBarTicker: StatusBarTickerToggle(isOn: $settings.showsStatusBarTicker, isAvailable: StatusBarCutout.isAvailable)
        case .linkBrowser: choicePicker(item, selection: $settings.linkBrowser, title: \.title)
        case .inAppBrowserHeight:
            // 本物のホームの上で選ぶので、設定の画面を重ねずに外へ出る。行の見た目は、ほかの画面へ入る行に揃え、シェブロンを付ける。
            Button(action: openInAppBrowserHeight) {
                HStack(spacing: 8) {
                    LabeledContent(item.title, value: SettingsItem.inAppBrowserHeightValue(in: settings))
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .tint(.primary)
        case .reblogVisibility: choicePicker(item, selection: $settings.reblogVisibility, title: \.title)
        case .composeBarIdle: choicePicker(item, selection: $settings.composeBarIdle, title: \.title)
        case .imageUploadSize: choicePicker(item, selection: $settings.imageUploadSize, title: \.title)
        case .videoUploadSize: choicePicker(item, selection: $settings.videoUploadSize, title: \.title)
        case .mediaDynamicRange: choicePicker(item, selection: $settings.mediaDynamicRange, title: \.title)
        case .viewerMediaDynamicRange: choicePicker(item, selection: $settings.viewerMediaDynamicRange, title: \.title)
        case .originalThumbnailsOnExpensiveNetwork: Toggle(item.title, isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
        case .ignoresUselessAltText: Toggle(item.title, isOn: $settings.ignoresUselessAltText)
        case .expandsXPosts: Toggle(item.title, isOn: $settings.expandsXPosts)
        case .version, .build, .branch, .commit, .builtAt, .sourceCode, .privacyPolicy:
            // 情報の画面（`AboutSettingsView`）が描く。
            EmptyView()
        }
    }

    private func choicePicker<Choice: CaseIterable & Hashable>(_ item: SettingsItem, selection: Binding<Choice>, title: KeyPath<Choice, String>) -> some View where Choice.AllCases: RandomAccessCollection {
        Picker(item.title, selection: selection) {
            ForEach(Choice.allCases, id: \.self) { choice in
                Text(choice[keyPath: title]).tag(choice)
            }
        }
    }
}

/// 見出しと説明があるときだけ、それを付ける節。説明は、文中のMarkdownのリンクを押せるリンクにする。
struct SettingsFormSection<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        switch (header, footer) {
        case (let header?, let footer?):
            Section { content } header: { Text(header) } footer: { Text(LocalizedStringKey(footer)) }
        case (let header?, nil):
            Section { content } header: { Text(header) }
        case (nil, let footer?):
            Section { content } footer: { Text(LocalizedStringKey(footer)) }
        case (nil, nil):
            Section { content }
        }
    }
}

/// アプリのアイコンを選ぶ画面。
struct AppIconSettingsView: View {
    @State private var appIconError: ErrorPresentation?

    /// 選択の表示は共有のAppIconSelectionから読む。設定を複数のウィンドウで開いていても、どれも同じ選択を表示する。
    private var appIconBinding: Binding<AppIconChoice> {
        Binding {
            AppDependencies.appIcon.current
        } set: { choice in
            appIconError = nil
            Task(.withoutRequests) {
                do {
                    try await AppDependencies.appIcon.select(choice)
                } catch {
                    appIconError = ErrorPresentation(error)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(SettingsTexts.AppIcon.picker, selection: appIconBinding) {
                    ForEach(AppIconChoice.allCases, id: \.self) { choice in
                        AppIconChoiceRow(choice: choice)
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                if let appIconError {
                    FailureReason(reason: appIconError, lead: SettingsTexts.AppIcon.failureLead)
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.appIcon.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 設定のトップの画面の、アプリのアイコンの画面へ入る行のラベル。分類の行の色付きの四角の代わりに、いま選んでいるアイコンを同じ大きさで添える。
struct AppIconSettingsLabel: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    var body: some View {
        Label {
            Text(SettingsPage.appIcon.rowTitle)
        } icon: {
            if let image = AppDependencies.appIcon.current.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                    // 白地のアイコンが行の背景に溶けないよう、選ぶリストと同じく縁を引く
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
            }
        }
    }
}

/// ステータスバーの通知の設定。使えない機種では、切り替えをオフにして灰色にし、理由を添える。
struct StatusBarTickerSettingsSection: View {
    @Binding var isOn: Bool
    /// この機種でステータスバーの通知を出せるか。
    let isAvailable: Bool

    var body: some View {
        Section {
            StatusBarTickerToggle(isOn: $isOn, isAvailable: isAvailable)
        } footer: {
            if !isAvailable {
                Text(SettingsTexts.Display.statusBarTickerUnavailable)
            }
        }
    }
}

struct StatusBarTickerToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool

    var body: some View {
        Toggle(SettingsItem.statusBarTicker.title, isOn: Binding { isAvailable && isOn } set: { isOn = $0 })
            .disabled(!isAvailable)
    }
}

/// アイコンを選ぶ行。ホーム画面と同じ見た目の絵と名前を並べる。
private struct AppIconChoiceRow: View {
    let choice: AppIconChoice

    var body: some View {
        HStack(spacing: 16) {
            if let image = choice.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 60, height: 60)
                    // 白地のアイコンは行の背景に溶けて輪郭が見えないため、ホーム画面の外でアイコンを見せるときの慣習にならって縁を引く
                    .overlay {
                        RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
            }
            Text(choice.title)
        }
    }
}
