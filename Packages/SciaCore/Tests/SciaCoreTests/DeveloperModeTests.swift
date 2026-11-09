import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct DeveloperModeTests {
    private func tap(_ mode: DeveloperMode, times: Int) -> [Bool] {
        (0..<times).map { _ in mode.registerTap() }
    }

    @Test func staysOffUntilTheRequiredTaps() {
        let mode = DeveloperMode(defaults: TestScratch.defaults("DeveloperModeTests"), isAlwaysEnabled: false)

        #expect(tap(mode, times: DeveloperMode.requiredTaps - 1).allSatisfy { !$0 })
        #expect(mode.isEnabled == false)
    }

    @Test func requiredTapsTurnItOnAndKeepItAcrossInstances() {
        let defaults = TestScratch.defaults("DeveloperModeTests")
        let mode = DeveloperMode(defaults: defaults, isAlwaysEnabled: false)

        #expect(tap(mode, times: DeveloperMode.requiredTaps).last == true)

        #expect(mode.isEnabled)
        #expect(DeveloperMode(defaults: defaults, isAlwaysEnabled: false).isEnabled)
    }

    @Test func theSameTapsTurnItOffAgain() {
        let defaults = TestScratch.defaults("DeveloperModeTests")
        let mode = DeveloperMode(defaults: defaults, isAlwaysEnabled: false)

        _ = tap(mode, times: DeveloperMode.requiredTaps)
        #expect(tap(mode, times: DeveloperMode.requiredTaps).last == true)

        #expect(mode.isEnabled == false)
        #expect(DeveloperMode(defaults: defaults, isAlwaysEnabled: false).isEnabled == false)
    }

    @Test func resetStartsTheCountOver() {
        let mode = DeveloperMode(defaults: TestScratch.defaults("DeveloperModeTests"), isAlwaysEnabled: false)

        _ = tap(mode, times: DeveloperMode.requiredTaps - 1)
        mode.resetTaps()
        _ = tap(mode, times: DeveloperMode.requiredTaps - 1)

        #expect(mode.isEnabled == false)
    }

    @Test func alwaysEnabledIgnoresTaps() {
        let mode = DeveloperMode(defaults: TestScratch.defaults("DeveloperModeTests"), isAlwaysEnabled: true)

        #expect(tap(mode, times: DeveloperMode.requiredTaps).allSatisfy { !$0 })
        #expect(mode.isEnabled)
    }
}
