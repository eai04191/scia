#if DEBUG
import os
import QuartzCore
import SciaCore
import UIKit

/// `scia-debug://text-benchmark`。画面に出ている本文のラベルの文字列を、UILabelが使う文字列の描画（`boundingRect`）、新しく作ったUILabel、TextKit 2で並べ、
/// かかった時間と高さと行数を、アプリのDocuments/AgentDump/text-benchmark.txtに書き出す。
/// 実機で長い本文の並べ方の重さを比べるため。本文の中身は書かず、文字数と数値だけを書く。
/// 同じ本文をメインスレッドの外でもTextKit 2で並べ、行の切れ目がメインスレッドと同じになるかと、かかった時間も書く。
@MainActor
enum TextLayoutBenchmark {
    static func write(in window: UIWindow?) {
        guard let window else { return }
        // 画面の外や、スクロールビューの見えている範囲の外にあるラベル（先に用意した行やプロフィールの見切れた部分）は測らない。
        let labels = Self.labels(in: window).filter { label in
            let visible = AgentScreenDump.visibleFrame(of: label, frame: label.convert(label.bounds, to: nil), screen: window.bounds)
            return !visible.isNull && visible.height >= 1 && label.alpha > 0 && (label.attributedText?.length ?? 0) > 0
        }
        var lines = ["model: \(UIDevice.current.model) \(UIDevice.current.systemVersion) repeats=\(repeats)"]
        for (index, label) in labels.enumerated() {
            guard let text = label.attributedText else { continue }
            let width = label.bounds.width
            let drawing = measure { text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height }
            let freshLabel = measure {
                let fresh = UILabel()
                fresh.numberOfLines = 0
                fresh.attributedText = text
                return fresh.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            }
            var textKitLines = 0
            let textKit = measure {
                let result = textKitLayout(of: label.textForTextKit ?? text, width: width)
                textKitLines = result.lines
                return result.height
            }
            let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
            let lineHeight = font?.lineHeight ?? 1
            lines.append("label \(index) length=\(text.length) width=\(width)")
            lines.append("  boundingRect: \(drawing.text) height=\(drawing.height) lines≈\(Int((drawing.height / lineHeight).rounded()))")
            lines.append("  UILabel:      \(freshLabel.text) height=\(freshLabel.height)")
            lines.append("  TextKit 2:    \(textKit.text) height=\(textKit.height) lines=\(textKitLines)")
        }
        let runs = labels.compactMap { label in label.textForTextKit.map { (Self.runs(of: $0), label.bounds.width) } }
        let mainResults = runs.map { Self.timedLayout(of: $0.0, width: $0.1) }
        Task {
            let background = await Task.detached { runs.map { Self.timedLayout(of: $0.0, width: $0.1) } }.value
            for (index, (onMain, offMain)) in zip(mainResults, background).enumerated() {
                let same = onMain.lineRanges == offMain.lineRanges && abs(onMain.height - offMain.height) < 0.01
                lines.append(String(format: "label %d メインスレッドの外: 行の切れ目と高さがメインスレッドと%@ main=%.2fms 外=%.2fms 外のスレッドか=%@", index, same ? "同じ" : "違う", onMain.seconds * 1000, offMain.seconds * 1000, offMain.isMainThread ? "いいえ" : "はい"))
            }
            save(lines.joined(separator: "\n") + "\n")
        }
    }

    /// 並べるのに要る属性だけを取り出した、Sendableな本文の断片。`NSAttributedString`はSendableではなく、メインスレッドの外へ渡せないため。
    struct Run: Sendable {
        let string: String
        let font: UIFont?
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let minimumLineHeight: CGFloat
        let firstLineHeadIndent: CGFloat
        let headIndent: CGFloat
        let alignment: Int
        let language: String?
        let attachmentImage: UIImage?
        let attachmentBounds: CGRect
    }

    private static func runs(of text: NSAttributedString) -> [Run] {
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let attachment = attributes[.attachment] as? NSTextAttachment
            runs.append(Run(
                string: (text.string as NSString).substring(with: range),
                font: attributes[.font] as? UIFont,
                lineSpacing: style?.lineSpacing ?? 0,
                paragraphSpacing: style?.paragraphSpacing ?? 0,
                minimumLineHeight: style?.minimumLineHeight ?? 0,
                firstLineHeadIndent: style?.firstLineHeadIndent ?? 0,
                headIndent: style?.headIndent ?? 0,
                alignment: style?.alignment.rawValue ?? NSTextAlignment.natural.rawValue,
                language: attributes[.languageIdentifier] as? String,
                attachmentImage: attachment?.image,
                attachmentBounds: attachment?.bounds ?? .zero
            ))
        }
        return runs
    }

    nonisolated private static func attributedString(of runs: [Run]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = run.lineSpacing
            style.paragraphSpacing = run.paragraphSpacing
            style.minimumLineHeight = run.minimumLineHeight
            style.firstLineHeadIndent = run.firstLineHeadIndent
            style.headIndent = run.headIndent
            style.alignment = NSTextAlignment(rawValue: run.alignment) ?? .natural
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if let font = run.font { attributes[.font] = font }
            if let language = run.language { attributes[.languageIdentifier] = language }
            if let image = run.attachmentImage {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = run.attachmentBounds
                attributes[.attachment] = attachment
            }
            result.append(NSAttributedString(string: run.string, attributes: attributes))
        }
        return result
    }

    struct TimedLayout: Sendable {
        let lineRanges: [NSRange]
        let height: CGFloat
        let seconds: Double
        let isMainThread: Bool
    }

    nonisolated private static func timedLayout(of runs: [Run], width: CGFloat) -> TimedLayout {
        let text = attributedString(of: runs)
        let start = Date()
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.attributedString = text
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var ranges: [NSRange] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { fragment in
            let base = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                ranges.append(NSRange(location: base + line.characterRange.location, length: line.characterRange.length))
            }
            return true
        }
        return TimedLayout(lineRanges: ranges, height: layoutManager.usageBoundsForTextContainer.height, seconds: Date().timeIntervalSince(start), isMainThread: Thread.isMainThread)
    }

    private static let repeats = 5

    /// `body`を`repeats`回走らせ、1回あたりの時間（最短と平均）と、最後に返した高さを返す。
    private static func measure(_ body: () -> CGFloat) -> (text: String, height: CGFloat) {
        var times: [CFTimeInterval] = []
        var height: CGFloat = 0
        for _ in 0..<repeats {
            let start = CACurrentMediaTime()
            height = body()
            times.append(CACurrentMediaTime() - start)
        }
        let average = times.reduce(0, +) / Double(times.count)
        return (String(format: "min=%.2fms avg=%.2fms", (times.min() ?? 0) * 1000, average * 1000), height)
    }

    /// `EmojiLabel`の並べ方と同じ設定で、行数を限らずに全文を並べる。
    private static func textKitLayout(of text: NSAttributedString, width: CGFloat) -> (height: CGFloat, lines: Int) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.attributedString = text
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var lines = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { fragment in
            lines += fragment.textLineFragments.count
            return true
        }
        return (layoutManager.usageBoundsForTextContainer.height, lines)
    }

    private static func labels(in view: UIView) -> [LinkLabel] {
        guard !view.isHidden else { return [] }
        if let label = view as? LinkLabel { return [label] }
        return view.subviews.flatMap(labels(in:))
    }

    private static func save(_ text: String) {
        do {
            let directory = URL.documentsDirectory.appending(path: "AgentDump")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appending(path: "text-benchmark.txt"), options: .atomic)
        } catch {
            SciaLog.logger(category: "debug").error("text benchmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
