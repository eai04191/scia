import Foundation
import Synchronization
import Testing
@testable import SciaCore

private let now = Date(timeIntervalSince1970: 1_000_000)

private func poll(
    id: String = "p1",
    expiresIn: TimeInterval? = 86_400,
    expired: Bool = false,
    multiple: Bool = false,
    votes: [Int?] = [3, 1],
    votersCount: Int? = nil,
    voted: Bool = false,
    ownVotes: [Int] = []
) -> Poll {
    Poll(
        id: id,
        expiresAt: expiresIn.map { now.addingTimeInterval($0) },
        expired: expired,
        multiple: multiple,
        votesCount: votes.compactMap(\.self).reduce(0, +),
        votersCount: votersCount,
        options: votes.enumerated().map { Poll.Option(title: "選択肢\($0.offset)", votesCount: $0.element) },
        voted: voted,
        ownVotes: ownVotes
    )
}

private func status(id: String = "10", poll: Poll?, reblog: Status? = nil) -> Status {
    Status(
        id: id,
        createdAt: Date(timeIntervalSince1970: 0),
        account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
        content: "<p>\(id)</p>",
        spoilerText: "",
        url: nil,
        poll: poll,
        reblog: reblog
    )
}

struct PollDisplayTests {
    @Test func votingBeforeVotingAndResultsAfterVoting() {
        #expect(PollDisplay(poll: poll(), choices: PollChoices(), now: now).mode == .voting)
        #expect(PollDisplay(poll: poll(voted: true, ownVotes: [0]), choices: PollChoices(), now: now).mode == .results)
    }

    /// サーバーの`expired`がまだfalseでも、締め切りの日時を過ぎていれば結果にする。
    /// 読んだのは締め切る前の結果なので、最終結果を読めるよう「更新」は残す。
    @Test func resultsOnceExpiresAtPasses() {
        let display = PollDisplay(poll: poll(expiresIn: -1), choices: PollChoices(), now: now)

        #expect(display.mode == .results)
        #expect(display.canRefresh)
        #expect(!display.canReturnToVoting)
        #expect(display.summary == "4票・終了")
    }

    /// サーバーが締め切ったと返した投票は、結果が変わらないため読み直さない。
    @Test func noRefreshOnceServerExpired() {
        let display = PollDisplay(poll: poll(expiresIn: -1, expired: true), choices: PollChoices(), now: now)

        #expect(display.mode == .results)
        #expect(!display.canRefresh)
    }

    /// 表示したまま締め切りを迎えたら、投票する形から結果の形に替わる。
    @Test func switchesToResultsWhenDeadlinePassesWhileShown() {
        var choices = PollChoices()
        choices.toggle(0, in: poll(expiresIn: 30))
        let before = PollDisplay(poll: poll(expiresIn: 30), choices: choices, now: now)
        let after = PollDisplay(poll: poll(expiresIn: 30), choices: choices, now: now.addingTimeInterval(31))

        #expect(before.mode == .voting)
        #expect(before.canSubmit)
        #expect(after.mode == .results)
        #expect(!after.canSubmit)
        #expect(before != after)
    }

    /// 投票の終了の通知のように、結果を知るための場所では、投票する形にしない。
    @Test func resultsWhenVotingIsNotAllowed() {
        let display = PollDisplay(poll: poll(), choices: PollChoices(), now: now, allowsVoting: false)

        #expect(display.mode == .results)
        #expect(!display.canReturnToVoting)
        #expect(!display.canRefresh)
    }

    @Test func fractionsUseVotersForMultipleChoicePolls() {
        let display = PollDisplay(poll: poll(multiple: true, votes: [3, 2], votersCount: 4, voted: true, ownVotes: [0, 1]), choices: PollChoices(), now: now)

        #expect(display.options.map(\.fraction) == [0.75, 0.5])
        #expect(display.options.map(\.isOwnVote) == [true, true])
        #expect(display.summary == "4人・残り1日")
    }

    @Test func leadingIncludesTiesAndNeedsVotes() {
        let tie = PollDisplay(poll: poll(votes: [2, 2, 1], voted: true), choices: PollChoices(), now: now)
        #expect(tie.options.map(\.isLeading) == [true, true, false])

        let empty = PollDisplay(poll: poll(votes: [0, 0], voted: true), choices: PollChoices(), now: now)
        #expect(empty.options.map(\.isLeading) == [false, false])
        #expect(empty.options.map(\.fraction) == [0, 0])
    }

    /// 締め切るまで票数を隠す投票では、割合を出さず、締め切り後に分かると書く。
    @Test func hiddenTotalsHaveNoFractions() {
        let display = PollDisplay(poll: poll(votes: [nil, nil], voted: true, ownVotes: [1]), choices: PollChoices(), now: now)

        #expect(display.options.map(\.fraction) == [nil, nil])
        #expect(display.options.map(\.isLeading) == [false, false])
        #expect(display.summary == "0票・残り1日・結果は締め切り後")
    }

    @Test func countsAreGroupedByThousands() {
        #expect(PollDisplay(poll: poll(multiple: true, votes: [123_456, 2], votersCount: 120_000), choices: PollChoices(), now: now).summary == "120,000人・残り1日")
    }

    /// 票数を隠す投票では、結果を見ても割合が出ないため、投票せずに結果を見られないようにする。
    @Test func cannotRevealHiddenTotals() {
        #expect(PollDisplay(poll: poll(), choices: PollChoices(), now: now).canRevealResults)
        #expect(!PollDisplay(poll: poll(votes: [nil, nil]), choices: PollChoices(), now: now).canRevealResults)
        #expect(!PollDisplay(poll: poll(voted: true), choices: PollChoices(), now: now).canRevealResults)
    }

    @Test func pollWithoutDeadlineShowsOnlyCount() {
        #expect(PollDisplay(poll: poll(expiresIn: nil), choices: PollChoices(), now: now).summary == "4票")
    }

    @Test(arguments: [
        (TimeInterval(59), "残り59秒"),
        (60, "残り1分"),
        (3_599, "残り59分"),
        (3_600, "残り1時間"),
        (86_399, "残り23時間"),
        (86_400 * 3 + 5, "残り3日"),
    ] as [(TimeInterval, String)])
    func remainingText(seconds: TimeInterval, expected: String) {
        #expect(PollDisplay.remainingText(until: now.addingTimeInterval(seconds), now: now) == expected)
    }

    @Test func canSubmitNeedsSelectionAndNotSubmitting() {
        var choices = PollChoices()
        #expect(!PollDisplay(poll: poll(), choices: choices, now: now).canSubmit)

        choices.toggle(1, in: poll())
        let selected = PollDisplay(poll: poll(), choices: choices, now: now)
        #expect(selected.canSubmit)
        #expect(selected.options.map(\.isSelected) == [false, true])

        choices.beginSubmitting("p1")
        let submitting = PollDisplay(poll: poll(), choices: choices, now: now)
        #expect(!submitting.canSubmit)
        #expect(submitting.isSubmitting)
    }

    /// 結果を見ると選んだら、結果の形にし、投票する形に戻れるようにする。選んでいた選択肢は戻ったときに残っている。
    @Test func revealShowsResultsAndKeepsSelection() {
        var choices = PollChoices()
        choices.toggle(0, in: poll())
        choices.reveal("p1")

        let revealed = PollDisplay(poll: poll(), choices: choices, now: now)
        #expect(revealed.mode == .results)
        #expect(revealed.canReturnToVoting)
        #expect(revealed.canRefresh)
        #expect(revealed.options.map(\.isSelected) == [false, false])

        choices.returnToVoting("p1")
        #expect(PollDisplay(poll: poll(), choices: choices, now: now).options.map(\.isSelected) == [true, false])
    }
}

struct PollChoicesTests {
    @Test func singleChoiceReplacesSelection() {
        var choices = PollChoices()
        choices.toggle(0, in: poll())
        choices.toggle(1, in: poll())
        choices.toggle(1, in: poll())

        #expect(choices.selection(of: poll()) == [1])
    }

    @Test func multipleChoiceToggles() {
        let multiple = poll(multiple: true, votes: [0, 0, 0])
        var choices = PollChoices()
        choices.toggle(0, in: multiple)
        choices.toggle(2, in: multiple)
        choices.toggle(0, in: multiple)

        #expect(choices.selection(of: multiple) == [2])
    }

    /// 選んだあとに編集で選択肢が変わったら、同じIDでも選んだものを忘れる。位置で覚えているため、別の選択肢を選んだことになるため。
    @Test func forgetsSelectionWhenOptionsAreEdited() {
        var choices = PollChoices()
        choices.toggle(0, in: poll())
        let edited = Poll(id: "p1", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: [.init(title: "全く別の案", votesCount: 0), .init(title: "選択肢1", votesCount: 0)])
        let madeMultiple = poll(multiple: true)

        #expect(choices.selection(of: edited).isEmpty)
        #expect(choices.selection(of: madeMultiple).isEmpty)
        #expect(!PollDisplay(poll: edited, choices: choices, now: now).canSubmit)
        #expect(choices.selection(of: poll(votes: [9, 9])) == [0])
    }

    @Test func ignoresOutOfRangeAndChangesWhileSubmitting() {
        var choices = PollChoices()
        choices.toggle(5, in: poll())
        #expect(choices.selection(of: poll()).isEmpty)

        choices.toggle(0, in: poll())
        choices.beginSubmitting("p1")
        choices.toggle(1, in: poll())
        #expect(choices.selection(of: poll()) == [0])
    }

    /// 投票できたら選んだものを忘れ、失敗したら押し直せるよう残す。
    @Test func endSubmittingForgetsSelectionOnlyOnSuccess() {
        var choices = PollChoices()
        choices.toggle(0, in: poll())
        choices.beginSubmitting("p1")
        choices.endSubmitting("p1", succeeded: false)
        #expect(choices.selection(of: poll()) == [0])
        #expect(!choices.isSubmitting("p1"))

        choices.reveal("p1")
        choices.beginSubmitting("p1")
        choices.endSubmitting("p1", succeeded: true)
        #expect(choices.selection(of: poll()).isEmpty)
        #expect(!choices.isRevealed("p1"))
    }
}

@MainActor
struct PollVotingTests {
    private struct Failure: Error {}

    /// 投稿をいくつか持ち、変換を当てた結果を記録する。
    private final class Shown {
        var statuses: [Status]

        init(_ statuses: [Status]) {
            self.statuses = statuses
        }

        func update(_ id: Status.ID, _ transform: (Status) -> Status) {
            statuses = statuses.map { status in
                if status.id == id { return transform(status) }
                if let reblog = status.reblog, reblog.id == id { return status.replacingReblog(with: transform(reblog)) }
                return status
            }
        }
    }

    @Test func voteSendsSortedChoicesAndAdoptsResultOnBoostedPost() async throws {
        let original = status(poll: poll(multiple: true))
        let boost = status(id: "20", poll: nil, reblog: original)
        let shown = Shown([original, boost])
        let sent = Mutex<[Int]>([])
        let result = poll(multiple: true, votes: [4, 2], votersCount: 5, voted: true, ownVotes: [0, 1])
        let voting = PollVoting(operations: .init(vote: { _, choices in
            sent.withLock { $0 = choices }
            return result
        }, poll: { _ in throw Failure() })) { shown.update($0, $1) }

        #expect(try await voting.vote([1, 0], on: boost))

        #expect(sent.withLock { $0 } == [0, 1])
        #expect(shown.statuses.map { $0.displayed.poll } == [result, result])
        #expect(voting.inFlight.isEmpty)
    }

    @Test func failedVoteLeavesPollUnchanged() async throws {
        let original = status(poll: poll())
        let shown = Shown([original])
        let voting = PollVoting(operations: .init(vote: { _, _ in throw Failure() }, poll: { _ in throw Failure() })) { shown.update($0, $1) }

        await #expect(throws: Failure.self) { try await voting.vote([0], on: original) }

        #expect(shown.statuses == [original])
        #expect(voting.inFlight.isEmpty)
    }

    @Test func ignoresEmptyChoicesAndSecondVoteWhileWaiting() async throws {
        let original = status(poll: poll())
        let shown = Shown([original])
        let gate = FetchGate()
        let calls = Mutex(0)
        let voting = PollVoting(operations: .init(vote: { _, _ in
            calls.withLock { $0 += 1 }
            await gate.wait()
            return poll(voted: true, ownVotes: [0])
        }, poll: { _ in throw Failure() })) { shown.update($0, $1) }

        #expect(try await !voting.vote([], on: original))
        let first = Task { try await voting.vote([0], on: original) }
        await gate.waitUntilWaiting()
        #expect(try await !voting.vote([1], on: original))
        #expect(try await !voting.refresh(original))
        await gate.open()

        #expect(try await first.value)
        #expect(calls.withLock { $0 } == 1)
        #expect(shown.statuses.first?.poll?.voted == true)
    }

    /// 読み直している間に投票が反映されたら、読み直した投票の前の結果で戻さない。
    @Test func refreshDuringVoteDoesNotRevertVote() async throws {
        let original = status(poll: poll())
        let shown = Shown([original])
        let gate = FetchGate()
        let voted = poll(votes: [4, 1], voted: true, ownVotes: [0])
        let voting = PollVoting(operations: .init(vote: { _, _ in voted }, poll: { _ in
            await gate.wait()
            return poll(votes: [3, 1])
        })) { shown.update($0, $1) }

        let refresh = Task { try await voting.refresh(original) }
        await gate.waitUntilWaiting()
        #expect(try await voting.vote([0], on: original))
        await gate.open()
        _ = try await refresh.value

        #expect(shown.statuses.first?.poll == voted)
        #expect(voting.refreshing.isEmpty)
    }

    @Test func refreshAdoptsLatestPoll() async throws {
        let original = status(poll: poll())
        let shown = Shown([original])
        let latest = poll(votes: [5, 9])
        let voting = PollVoting(operations: .init(vote: { _, _ in throw Failure() }, poll: { _ in latest })) { shown.update($0, $1) }

        #expect(try await voting.refresh(original))

        #expect(shown.statuses.first?.poll == latest)
    }
}

struct StatusPollTests {
    /// 待っている間に編集で投票が作り直されていたら、前の投票の結果で差し替えない。
    @Test func adoptingPollIgnoresOtherPoll() {
        let edited = status(poll: poll(id: "p2"))

        #expect(edited.adoptingPoll(poll(id: "p1", voted: true)) == edited)
        #expect(edited.adoptingPoll(poll(id: "p2", voted: true)).poll?.voted == true)
    }

    /// Mastodonは編集で選択肢を変えても投票のIDを変えないため、選択肢が違う結果は編集の前のものとして差し替えない。
    @Test func adoptingPollIgnoresResultWithOldOptions() {
        let edited = status(poll: poll(votes: [0, 0, 0]))

        #expect(edited.adoptingPoll(poll(votes: [5, 1])) == edited)
        #expect(edited.adoptingPoll(poll(multiple: true, votes: [0, 0, 0])) == edited)
        #expect(edited.adoptingPoll(poll(votes: [1, 0, 0], voted: true)).poll?.voted == true)
    }

    @Test func emojisInRowIncludePollEmojis() throws {
        let emoji = CustomEmoji(shortcode: "blobcat", url: try #require(URL(string: "https://example.social/e.png")), staticUrl: try #require(URL(string: "https://example.social/e.png")))
        let withEmoji = Poll(id: "p1", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: [.init(title: ":blobcat:", votesCount: 0)], emojis: [emoji])

        #expect(status(poll: withEmoji).emojisInRow.map(\.shortcode) == ["blobcat"])
    }
}

struct PollDraftTests {
    private let limits = PollLimits.mastodonDefault

    @Test func needsTwoFilledOptions() {
        #expect(!PollDraft(options: ["朝", ""]).isValid(limits: limits))
        #expect(!PollDraft(options: ["朝", "   "]).isValid(limits: limits))
        #expect(PollDraft(options: ["朝", "", "夜"]).isValid(limits: limits))
    }

    /// Mastodonと同じく、前後の空白を除いてから、同じ選択肢がないかと文字数を見る。
    @Test func rejectsDuplicatesAndLongOptions() {
        #expect(!PollDraft(options: ["朝", " 朝 "]).isValid(limits: limits))
        #expect(!PollDraft(options: ["朝", String(repeating: "あ", count: 51)]).isValid(limits: limits))
        #expect(PollDraft(options: ["朝", " " + String(repeating: "あ", count: 50) + " "]).isValid(limits: limits))
    }

    @Test func rejectsTooManyOptionsAndOutOfRangeExpiry() {
        #expect(!PollDraft(options: ["1", "2", "3", "4", "5"]).isValid(limits: limits))
        #expect(!PollDraft(options: ["朝", "夜"], expiresIn: 60).isValid(limits: limits))
    }

    /// 最後の欄に書くと、上限まで後ろに空の欄を1つ足す。
    @Test func writingLastOptionAddsEmptyField() {
        var poll = PollDraft()
        poll.setOption("朝", at: 0, limits: limits)
        #expect(poll.options == ["朝", ""])
        poll.setOption("昼", at: 1, limits: limits)
        #expect(poll.options == ["朝", "昼", ""])
        poll.setOption("夜", at: 2, limits: limits)
        poll.setOption("深夜", at: 3, limits: limits)
        #expect(poll.options == ["朝", "昼", "夜", "深夜"])
    }

    /// 後ろに空の欄が並んだら1つに詰め、2つより減らさない。途中の空の欄は詰めない。
    @Test func clearingTrimsTrailingEmptyFields() {
        var poll = PollDraft(options: ["朝", "昼", ""])
        poll.setOption("", at: 1, limits: limits)
        #expect(poll.options == ["朝", ""])
        poll.setOption("", at: 0, limits: limits)
        #expect(poll.options == ["", ""])

        var middle = PollDraft(options: ["朝", "昼", "夜", ""])
        middle.setOption("", at: 1, limits: limits)
        #expect(middle.options == ["朝", "", "夜", ""])
    }

    /// 空白だけの欄は空として扱う。
    @Test func whitespaceOnlyCountsAsEmpty() {
        var poll = PollDraft(options: ["朝", ""])
        poll.setOption(" ", at: 1, limits: limits)
        #expect(poll.options == ["朝", " "])
    }


    @Test func expiryTitles() {
        #expect(PollDraft.expiryChoices.map(PollDraft.expiryTitle) == ["5分", "30分", "1時間", "6時間", "12時間", "1日", "3日", "7日"])
        #expect(PollDraft.expiryTitle(5_400) == "90分")
    }

    @Test func expiryChoicesStayWithinServerLimits() {
        let limits = PollLimits(maxOptions: 4, maxCharactersPerOption: 50, expirationRange: 600...86_400)
        #expect(PollDraft.expiryChoices(within: limits) == [1_800, 3_600, 21_600, 43_200, 86_400])
    }

    /// 投票は、本文がなければ送れず、添付とは一緒に送れない。
    @Test func canPostNeedsTextAndNoAttachments() {
        let poll = PollDraft(options: ["朝", "夜"])
        #expect(StatusDraft(text: "どっち", poll: poll).canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4))
        #expect(!StatusDraft(text: " ", poll: poll).canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4))
        #expect(!StatusDraft(text: "どっち", poll: PollDraft()).canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4))
        let attachment = DraftAttachment(state: .uploaded(MediaAttachment(id: "m1", type: .image, url: URL(string: "https://example.social/m1.png"), previewUrl: nil)))
        #expect(!StatusDraft(text: "どっち", attachments: [attachment], poll: poll).canPost(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4))
    }
}
