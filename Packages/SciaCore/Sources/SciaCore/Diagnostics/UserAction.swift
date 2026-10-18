import Foundation
import OSLog

/// 違和感レポートで「直前に何をしたか」を組み立てるために、ログに残すユーザーの操作。
/// ログの本文は`名前 引数...`の形で書き、`OperationTimeline`が読み戻して文章にする。
public enum UserAction: Sendable, Equatable {
    case selectTab(String)
    /// 選んでいるタブをもう一度押した。
    case reselectTab(String)
    /// 指で一覧を動かし、止まった。
    case scroll(ScrollRecord)
    /// ステータスバーを押して最上部へ動かした。
    case scrollToTop(screen: String)
    case tapNewArrivals(screen: String)
    case tapGap(screen: String)
    /// 長押しで投稿のメニューを出した。
    case openMenu(screen: String)
    case openViewer(count: Int, index: Int)
    case closeViewer(ViewerClose)
    case openProfile
    case reply
    case toggleFavourite
    case toggleReblog
    case editStatus
    case deleteStatus
    case expandCompose
    case submitPost
    case enterForeground
    case enterBackground

    public enum ViewerClose: String, Sendable {
        case drag
        case button
    }

    public static let logCategory = "action"

    public var logMessage: String {
        switch self {
        case .selectTab(let tab): "tab.select \(tab)"
        case .reselectTab(let tab): "tab.reselect \(tab)"
        case .scroll(let record):
            "scroll \(record.screen) \(record.direction.rawValue) \(Self.number(record.pages)) \(Self.number(record.duration)) \(record.hitches.droppedFrames) \(Self.number(record.hitches.hitchTime, digits: 3))"
        case .scrollToTop(let screen): "scroll.top \(screen)"
        case .tapNewArrivals(let screen): "newArrivals.tap \(screen)"
        case .tapGap(let screen): "gap.tap \(screen)"
        case .openMenu(let screen): "menu.open \(screen)"
        case .openViewer(let count, let index): "viewer.open \(count) \(index)"
        case .closeViewer(let method): "viewer.close \(method.rawValue)"
        case .openProfile: "profile.open"
        case .reply: "status.reply"
        case .toggleFavourite: "status.favourite"
        case .toggleReblog: "status.reblog"
        case .editStatus: "status.edit"
        case .deleteStatus: "status.delete"
        case .expandCompose: "compose.expand"
        case .submitPost: "compose.submit"
        case .enterForeground: "app.foreground"
        case .enterBackground: "app.background"
        }
    }

    /// `logMessage`から読み戻す。知らない名前や引数の数が合わないものはnilにする。
    public init?(logMessage: String) {
        let parts = logMessage.split(separator: " ").map(String.init)
        guard let name = parts.first else { return nil }
        let args = Array(parts.dropFirst())
        switch (name, args.count) {
        case ("tab.select", 1): self = .selectTab(args[0])
        case ("tab.reselect", 1): self = .reselectTab(args[0])
        case ("scroll", 6):
            guard let direction = ScrollRecord.Direction(rawValue: args[1]),
                  let pages = Double(args[2]),
                  let duration = Double(args[3]),
                  let droppedFrames = Int(args[4]),
                  let hitchTime = Double(args[5])
            else { return nil }
            self = .scroll(ScrollRecord(
                screen: args[0],
                direction: direction,
                pages: pages,
                duration: duration,
                hitches: HitchCounter.Summary(droppedFrames: droppedFrames, hitchTime: hitchTime)
            ))
        case ("scroll.top", 1): self = .scrollToTop(screen: args[0])
        case ("newArrivals.tap", 1): self = .tapNewArrivals(screen: args[0])
        case ("gap.tap", 1): self = .tapGap(screen: args[0])
        case ("menu.open", 1): self = .openMenu(screen: args[0])
        case ("viewer.open", 2):
            guard let count = Int(args[0]), let index = Int(args[1]) else { return nil }
            self = .openViewer(count: count, index: index)
        case ("viewer.close", 1):
            guard let method = ViewerClose(rawValue: args[0]) else { return nil }
            self = .closeViewer(method)
        case ("profile.open", 0): self = .openProfile
        case ("status.reply", 0): self = .reply
        case ("status.favourite", 0): self = .toggleFavourite
        case ("status.reblog", 0): self = .toggleReblog
        case ("status.edit", 0): self = .editStatus
        case ("status.delete", 0): self = .deleteStatus
        case ("compose.expand", 0): self = .expandCompose
        case ("compose.submit", 0): self = .submitPost
        case ("app.foreground", 0): self = .enterForeground
        case ("app.background", 0): self = .enterBackground
        default: return nil
        }
    }

    /// 違和感レポートに残すため、infoレベルで書く。
    public func record() {
        Logger(subsystem: SciaLog.subsystem, category: Self.logCategory).info("\(logMessage, privacy: .public)")
    }

    /// 違和感レポートの一覧に出す、人が読む説明。
    public var summary: String {
        switch self {
        case .selectTab(let tab): "\(Self.screenName(tab))のタブを選んだ"
        case .reselectTab(let tab): "\(Self.screenName(tab))のタブをもう一度押した"
        case .scroll(let record): Self.summary(of: record)
        case .scrollToTop(let screen): "ステータスバーを押して\(Self.screenName(screen))の最上部へ戻った"
        case .tapNewArrivals(let screen): "\(Self.screenName(screen))の新着ボタンを押した"
        case .tapGap(let screen): "\(Self.screenName(screen))の読み込んでいない部分を押した"
        case .openMenu(let screen): "\(Self.screenName(screen))で投稿を長押ししてメニューを開いた"
        case .openViewer(let count, let index): count == 1 ? "メディアをビューアで開いた" : "\(count)件のメディアの\(index + 1)件目をビューアで開いた"
        case .closeViewer(.drag): "ビューアをドラッグして閉じた"
        case .closeViewer(.button): "ビューアを閉じた"
        case .openProfile: "プロフィールを開いた"
        case .reply: "投稿への返信を書き始めた"
        // 投稿への操作と投稿は通信の前に記録するため、失敗した場合や応答を待つ間もあるので、成功したとは書かない。
        case .toggleFavourite: "投稿のお気に入りを押した"
        case .toggleReblog: "投稿のブーストを押した"
        case .editStatus: "自分の投稿の編集を選んだ"
        case .deleteStatus: "自分の投稿の削除を決めた"
        case .expandCompose: "投稿欄を広げた"
        case .submitPost: "投稿を送った"
        case .enterForeground: "アプリに戻った"
        case .enterBackground: "アプリを離れた"
        }
    }

    private static func summary(of record: ScrollRecord) -> String {
        let direction = record.direction == .down ? "下" : "上"
        var details = [String(format: "%.1f秒", record.duration)]
        if record.hitches.droppedFrames > 0 {
            details.append("落ちたフレーム\(record.hitches.droppedFrames)・計\(Int((record.hitches.hitchTime * 1000).rounded()))ms")
        }
        return "\(screenName(record.screen))を\(direction)へ\(String(format: "%.1f", record.pages))画面分スクロールした（\(details.joined(separator: "、"))）"
    }

    /// ログの本文に書く数値。端末の地域の設定で小数点が変わらないよう、`String(format:)`で書く。
    private static func number(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func screenName(_ id: String) -> String {
        switch id {
        case "home", "timeline": "ホーム"
        case "notifications": "通知"
        case "profile": "プロフィール"
        default: id
        }
    }
}
