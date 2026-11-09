import Foundation
import SciaCore
import SciaTesting
import Testing

@MainActor @Suite(.scratch) struct PostQuarantineTests {
    @Test func 足した投稿を隔離する() {
        let quarantine = PostQuarantine(defaults: TestScratch.defaults("quarantine"), build: "1")
        quarantine.add(accountID: "a", statusID: "10")
        #expect(quarantine.contains(statusID: "10"))
        #expect(!quarantine.contains(statusID: "11"))
    }

    @Test func 起動し直しても同じビルドなら残る() {
        let defaults = TestScratch.defaults("quarantine")
        PostQuarantine(defaults: defaults, build: "1").add(accountID: "a", statusID: "10")
        #expect(PostQuarantine(defaults: defaults, build: "1").contains(statusID: "10"))
    }

    @Test func ビルドが変わると解除する() {
        let defaults = TestScratch.defaults("quarantine")
        PostQuarantine(defaults: defaults, build: "1").add(accountID: "a", statusID: "10")
        #expect(!PostQuarantine(defaults: defaults, build: "2").contains(statusID: "10"))
        // 前のビルドに戻しても、消したものは戻らない。
        #expect(!PostQuarantine(defaults: defaults, build: "1").contains(statusID: "10"))
    }

    @Test func ビルドが変わった起動かが分かる() {
        let defaults = TestScratch.defaults("quarantine")
        #expect(PostQuarantine(defaults: defaults, build: "1").isNewBuild)
        #expect(!PostQuarantine(defaults: defaults, build: "1").isNewBuild)
        #expect(PostQuarantine(defaults: defaults, build: "2").isNewBuild)
    }

    @Test func 伝えるのは同じ投稿につき一度だけ() {
        let defaults = TestScratch.defaults("quarantine")
        let quarantine = PostQuarantine(defaults: defaults, build: "1")
        quarantine.add(accountID: "a", statusID: "10")
        quarantine.add(accountID: "a", statusID: "10")
        quarantine.add(accountID: "b", statusID: "20")
        #expect(quarantine.takeUnnotified(accountID: "a") == ["10"])
        #expect(quarantine.takeUnnotified(accountID: "a").isEmpty)
        #expect(PostQuarantine(defaults: defaults, build: "1").takeUnnotified(accountID: "a").isEmpty)
        #expect(PostQuarantine(defaults: defaults, build: "1").takeUnnotified(accountID: "b") == ["20"])
    }
}
