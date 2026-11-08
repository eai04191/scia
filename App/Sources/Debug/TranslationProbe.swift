#if DEBUG
import Foundation
import SciaCore
import Translation

/// `scia-debug://translation-probe`。Translationフレームワークの言語の状態、速度、本文の保持を実機で測り、アプリのDocuments/AgentDump/translation.txtに書き足す。
/// シミュレーターでは翻訳が`unsupported`になるため、画面を見ずにdevicectlで取り出して確かめる。
@available(iOS 26.4, *)
enum TranslationProbe {
    private static let japanese = Locale.Language(identifier: "ja")
    private static let english = Locale.Language(identifier: "en")
    private static let posts = [
        "Just shipped a new version of my app. The timeline scrolling feels so much better now!",
        "Does anyone know a good bakery near the central station? I'm visiting next week.",
        "It rained all day so I stayed in and finally finished that book I started in March.",
        "Hot take: tabs are fine, spaces are fine, please stop arguing and go outside.",
        "The cat has decided the keyboard is her bed. Work is cancelled today.",
        "Reminder that the community meetup is this Saturday at 3pm. Bring snacks!",
        "I spent four hours debugging only to find a missing comma. Software is a beautiful profession.",
        "New blog post about how we moved our database without downtime. Lessons learned inside.",
        "Saw the most incredible sunset on the way home tonight. No filter, I promise.",
        "Can we talk about how good this soup is? I have made it three times this week.",
    ]

    @MainActor private static var isRunning = false

    /// 測っている間の再要求は無視する。並べて走らせると、ファイルへの書き足しが欠け、速度の条件も崩れるため。
    @MainActor
    static func start() {
        guard !isRunning else { return }
        isRunning = true
        Task(.withoutRequests) {
            await run()
            isRunning = false
        }
    }

    @concurrent
    private static func run() async {
        log("==== start")
        await statuses()
        await measure(label: "default", TranslationSession(installedSource: english, target: japanese))
        await measure(label: "lowLatency", TranslationSession(installedSource: english, target: japanese, preferredStrategy: .lowLatency))
        await measure(label: "highFidelity", TranslationSession(installedSource: english, target: japanese, preferredStrategy: .highFidelity))
        await preservation()
        log("==== end")
    }

    private static func statuses() async {
        let strategies: [(String, LanguageAvailability)] = [
            ("default", LanguageAvailability()),
            ("lowLatency", LanguageAvailability(preferredStrategy: .lowLatency)),
            ("highFidelity", LanguageAvailability(preferredStrategy: .highFidelity)),
        ]
        for (name, availability) in strategies {
            var line = "status \(name):"
            for identifier in ["en", "ko", "zh-Hans", "de", "fr", "es"] {
                let status = await availability.status(from: Locale.Language(identifier: identifier), to: japanese)
                line += " \(identifier)=\(status)"
            }
            log(line)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func measure(label: String, _ session: TranslationSession) async {
        log("== speed \(label) isReady=\(await session.isReady)")
        do {
            for index in 0..<5 {
                let start = ContinuousClock.now
                let response = try await session.translate(posts[index])
                log("single\(index) \(milliseconds(since: start))ms \(response.targetText)")
            }
            for count in [10, 50] {
                let requests = (0..<count).map { TranslationSession.Request(sourceText: posts[$0 % posts.count] + " #\($0)", clientIdentifier: "\($0)") }
                let start = ContinuousClock.now
                var first: Int?
                var received = 0
                for try await _ in session.translate(batch: requests) {
                    if first == nil { first = milliseconds(since: start) }
                    received += 1
                }
                log("batch\(count) first=\(first ?? -1)ms total=\(milliseconds(since: start))ms received=\(received)")
            }
        } catch {
            log("error \(String(reflecting: error))")
        }
    }

    private static func attributed(_ parts: [(text: String, link: String?, skips: Bool)]) -> AttributedString {
        var result = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            if let link = part.link { piece.link = URL(string: link) }
            if part.skips { piece.translation.skipsTranslation = true }
            result += piece
        }
        return result
    }

    private static func preservation() async {
        log("== preservation")
        let session = TranslationSession(installedSource: english, target: japanese)
        for text in ["First line.\n\nSecond paragraph after blank line.\nThird line.", "@alice@example.social thanks! See https://example.com/a?b=1 #swift", "I love this :blobcat_happy: so much :party_parrot:"] {
            do {
                log("plain \(try await session.translate(text).targetText.debugDescription)")
            } catch {
                log("plain error \(String(reflecting: error))")
            }
        }
        let cases = [
            attributed([("Thanks ", nil, false), ("@alice", "https://example.social/@alice", true), (" for the tip! See ", nil, false), ("example.com/path", "https://example.com/path?a=1", true), (" for more ", nil, false), ("#swift", "https://example.social/tags/swift", true)]),
            attributed([("I love this ", nil, false), (":blobcat_happy:", nil, true), (" so much ", nil, false), (":party_parrot:", nil, true)]),
            attributed([("I love this ", nil, false), ("\u{FFFC}", nil, true), (" so much ", nil, false), ("\u{FFFC}", nil, true)]),
        ]
        for input in cases {
            do {
                guard let output = try await session.translate(input).attributedTargetText else {
                    log("attributed nil")
                    continue
                }
                let runs = output.runs.map { "[\(String(output[$0.range].characters).debugDescription) link=\($0.link?.absoluteString ?? "-") skip=\($0.translation.skipsTranslation.map(String.init(describing:)) ?? "-")]" }
                log("attributed \(runs.joined())")
            } catch {
                log("attributed error \(String(reflecting: error))")
            }
        }
    }

    private static func log(_ line: String) {
        let directory = URL.documentsDirectory.appending(path: "AgentDump", directoryHint: .isDirectory)
        let file = directory.appending(path: "translation.txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try (existing + line + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            assertionFailure("translation probe could not write: \(error)")
        }
    }
}
#endif
