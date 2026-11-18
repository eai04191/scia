import Foundation
import Testing
@testable import SciaCore

struct PresetLibraryTests {
    /// 子が値を持たない項目は、親から順にたどって組み込みのプリセットまで読む。
    @Test func valueFallsThroughToAncestors() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        try library.setValue(.number(18), forKey: "bodySize", in: base)
        let home = try library.create(parent: base, name: "家")
        try library.setValue(.number(2), forKey: "mediaScale", in: home)

        #expect(library.value(forKey: "bodySize", in: home) == .number(18))
        #expect(library.value(forKey: "mediaScale", in: home) == .number(2))
        #expect(library.value(forKey: "mediaScale", in: base) == nil)
        #expect(library.ancestors(of: home) == [base, .builtIn(.standard)])
    }

    /// 親の値を変えると、変えていない子の項目も新しい値になる。
    @Test func childFollowsParentChanges() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        let home = try library.create(parent: base, name: "家")
        try library.setValue(.number(18), forKey: "bodySize", in: base)
        #expect(library.value(forKey: "bodySize", in: home) == .number(18))
        try library.setValue(.number(20), forKey: "bodySize", in: base)
        #expect(library.value(forKey: "bodySize", in: home) == .number(20))
    }

    /// 値が親と同じになっても変えた項目として残し、親がそのあと変わっても子の値は変わらない。
    @Test func modifiedValueEqualToParentStaysModified() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        let home = try library.create(parent: base, name: "家")
        try library.setValue(.number(20), forKey: "bodySize", in: home)
        try library.setValue(.number(20), forKey: "bodySize", in: base)
        #expect(library.isModified("bodySize", in: home))

        try library.setValue(.number(22), forKey: "bodySize", in: base)
        #expect(library.value(forKey: "bodySize", in: home) == .number(20))

        try library.resetValue(forKey: "bodySize", in: home)
        #expect(!library.isModified("bodySize", in: home))
        #expect(library.value(forKey: "bodySize", in: home) == .number(22))
    }

    /// 組み込みのプリセットを使っているときに値を変えると、それを親にした番号付きのプリセットを作り、そちらに切り替える。
    @Test func editingBuiltInCreatesNumberedChild() throws {
        var library = PresetLibrary()
        let created = try library.setValue(.bool(false), forKey: "showsActionBar", for: .app)

        #expect(library.appPreset == created)
        #expect(library.name(of: created) == "標準 2")
        #expect(library.ancestors(of: created) == [.builtIn(.standard)])
        #expect(library.value(forKey: "showsActionBar", in: created) == .bool(false))

        // 次に変えるときは、作ったプリセットを変え、もう作らない。
        let again = try library.setValue(.bool(true), forKey: "showsTime", for: .app)
        #expect(again == created)
        #expect(library.userPresets.count == 1)
    }

    /// アカウントが組み込みのプリセットを割り当てていれば、アカウントの割り当てだけを作ったプリセットに切り替える。
    @Test func editingAccountBuiltInSwitchesOnlyThatAccount() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        try library.select(home, for: .app)
        try library.select(.builtIn(.standard), for: .account("a@example.social"))

        let created = try library.setValue(.number(1), forKey: "bodySize", for: .account("a@example.social"))

        #expect(library.preset(forAccount: "a@example.social") == created)
        #expect(library.appPreset == home)
        #expect(library.name(of: created) == "標準 2")
    }

    /// 割り当てていないアカウントで値を変えると、アプリのプリセットに入る。組み込みのプリセットなら、作ったプリセットをアプリに選び、アカウントには割り当てない。
    @Test func editingFromUnassignedAccountChangesApp() throws {
        var library = PresetLibrary()
        let created = try library.setValue(.bool(false), forKey: "showsTime", for: .account("a@example.social"))
        #expect(library.appPreset == created)
        #expect(library.accountPresets.isEmpty)
    }

    /// 割り当てていないアカウントは、アプリのプリセットに従い、アプリのプリセットを切り替えると一緒に変わる。
    @Test func unassignedAccountFollowsApp() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        let outside = try library.create(parent: .builtIn(.standard), name: "外")
        try library.select(outside, for: .account("b@example.social"))
        try library.select(home, for: .app)

        #expect(library.preset(forAccount: "a@example.social") == home)
        #expect(library.preset(forAccount: "b@example.social") == outside)

        library.unassign(account: "b@example.social")
        #expect(library.preset(forAccount: "b@example.social") == home)
    }

    /// 子を持つプリセットを消すと、変えた項目を子に引き継ぎ、子の親を付け替える。子の値は変わらない。
    @Test func deletingParentKeepsChildValues() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        try library.setValue(.number(18), forKey: "bodySize", in: base)
        try library.setValue(.bool(false), forKey: "showsTime", in: base)
        let home = try library.create(parent: base, name: "家")
        try library.setValue(.bool(true), forKey: "showsTime", in: home)
        let before = ["bodySize", "showsTime"].map { library.value(forKey: $0, in: home) }

        try library.delete(base)

        #expect(["bodySize", "showsTime"].map { library.value(forKey: $0, in: home) } == before)
        #expect(library.ancestors(of: home) == [.builtIn(.standard)])
        #expect(library.isModified("bodySize", in: home))
    }

    /// 使っているプリセットを消すと、それを使っていたアプリとアカウントを、その親に切り替える。
    @Test func deletingUsedPresetSwitchesToParent() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        let home = try library.create(parent: base, name: "家")
        try library.select(home, for: .app)
        try library.select(home, for: .account("a@example.social"))

        try library.delete(home)

        #expect(library.appPreset == base)
        #expect(library.accountPresets["a@example.social"] == base)
    }

    /// 複製は同じ親と同じ変えた項目を持ち、元の名前に使っていない最小の番号を付ける。
    @Test func duplicateKeepsParentAndValues() throws {
        var library = PresetLibrary()
        let base = try library.create(parent: .builtIn(.standard), name: "自分用")
        let home = try library.create(parent: base, name: "家")
        try library.setValue(.number(2), forKey: "mediaScale", in: home)

        let first = try library.duplicate(home)
        let second = try library.duplicate(home)

        #expect(library.name(of: first) == "家 2")
        #expect(library.name(of: second) == "家 3")
        #expect(library.ancestors(of: first) == [base, .builtIn(.standard)])
        #expect(library.value(forKey: "mediaScale", in: first) == .number(2))
        #expect(library.isModified("mediaScale", in: first))
    }

    /// 消したプリセットを選ぶ操作（ショートカット）は、何も変えずに失敗する。
    @Test func selectingDeletedPresetFails() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        try library.delete(home)
        let before = library

        #expect(throws: PresetError.presetNotFound) { try library.select(home, for: .app) }
        #expect(throws: PresetError.presetNotFound) { try library.select(home, for: .account("a@example.social")) }
        #expect(library == before)
    }

    /// ほかの使う人のプリセットが使っている名前は付けられない。組み込みのプリセットの名前とは重なってもよい。
    @Test func rejectsTakenName() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        let outside = try library.create(parent: .builtIn(.standard), name: "外")
        let before = library

        #expect(throws: PresetError.nameTaken) { try library.rename(outside, to: "家") }
        #expect(throws: PresetError.nameTaken) { try library.create(parent: home, name: "家") }
        #expect(library == before)

        try library.rename(outside, to: "標準")
        #expect(library.name(of: outside) == "標準")

        // 自分の今の名前に付け直すのは断らない。
        try library.rename(home, to: "家")
        #expect(library.name(of: home) == "家")
    }

    @Test func builtInIsReadOnly() {
        var library = PresetLibrary()
        #expect(throws: PresetError.builtInIsReadOnly) { try library.setValue(.bool(true), forKey: "showsTime", in: .builtIn(.standard)) }
        #expect(throws: PresetError.builtInIsReadOnly) { try library.delete(.builtIn(.standard)) }
    }

    /// 消したプリセットの番号を、あとで作るプリセットに使い回さない。ショートカットが消したプリセットを指したまま、別のプリセットに切り替えないため。
    @Test func deletedNumberIsNotReused() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        try library.delete(home)
        let next = try library.create(parent: .builtIn(.standard), name: "外")
        #expect(next != home)
    }

    @Test func roundTripsThroughStorage() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        try library.setValue(.list(["reply", "favourite"]), forKey: "actionBar", in: home)
        try library.setValue(.text("inApp"), forKey: "linkBrowser", in: home)
        try library.select(home, for: .account("a@example.social"))

        let restored = PresetLibrary(stored: library.storedData)
        #expect(restored == library)
        // 番号の続きも読み戻し、作り直しても前のプリセットと重ならない。
        var relaunched = restored
        #expect(try relaunched.create(parent: .builtIn(.standard)) != home)
    }

    /// 親が循環した保存の形は、読まずに何も作っていない状態にする。値をたどる処理が止まらなくなるため。
    @Test func cyclicStorageIsDiscarded() throws {
        let json = """
        {"userPresets":[{"id":1,"name":"A","parent":{"user":{"_0":2}},"values":{}},{"id":2,"name":"B","parent":{"user":{"_0":1}},"values":{}}],
         "appPreset":{"builtIn":{"_0":"standard"}},"accountPresets":{},"nextUserID":3}
        """
        let library = PresetLibrary(stored: Data(json.utf8))
        #expect(library == PresetLibrary())

        // 同じ形で循環していなければ読む。上で読まなかったのが、形が違うせいではないことを確かめる。
        let acyclic = json.replacingOccurrences(of: #""parent":{"user":{"_0":1}}"#, with: #""parent":{"builtIn":{"_0":"standard"}}"#)
        #expect(PresetLibrary(stored: Data(acyclic.utf8)).userPresets.count == 2)
    }

    /// 数でない値（NaNや無限）は保存の形に書けず、ほかのプリセットまで読み戻せなくなるので、何も変えずに断る。
    /// 組み込みのプリセットを使っているときも、プリセットを作らない。
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func rejectsNonFiniteNumbers(_ number: Double) throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        library = PresetLibrary(stored: library.storedData)
        let before = library

        #expect(throws: PresetError.invalidValue) { try library.setValue(.number(number), forKey: "bodySize", in: home) }
        try library.select(.builtIn(.standard), for: .app)
        let selected = library
        #expect(throws: PresetError.invalidValue) { try library.setValue(.number(number), forKey: "bodySize", for: .app) }
        #expect(library == selected)
        #expect(PresetLibrary(stored: library.storedData).userPreset(1) == before.userPreset(1))
    }

    /// 次の番号が振れない保存の形は、読まずに何も作っていない状態にする。作るときに数があふれて落ちるため。
    @Test func storageWithExhaustedNumberIsDiscarded() throws {
        let json = """
        {"userPresets":[],"appPreset":{"builtIn":{"_0":"standard"}},"accountPresets":{},"nextUserID":\(Int.max)}
        """
        var library = PresetLibrary(stored: Data(json.utf8))
        #expect(library == PresetLibrary())
        #expect(try library.create(parent: .builtIn(.standard)) == .user(1))
    }

    /// ログアウトしたアカウントの割り当ては忘れ、同じハンドルでログインし直しても、アプリのプリセットに従う。
    @Test func forgetsLoggedOutAccount() throws {
        var library = PresetLibrary()
        let home = try library.create(parent: .builtIn(.standard), name: "家")
        try library.select(home, for: .account("a@example.social"))
        library.forgetAccount("a@example.social")
        #expect(library.preset(forAccount: "a@example.social") == .builtIn(.standard))
    }
}
