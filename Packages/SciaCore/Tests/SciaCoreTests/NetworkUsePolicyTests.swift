import Testing
@testable import SciaCore

struct NetworkUsePolicyTests {
    private let wifi = NetworkConditions(isConstrained: false, isExpensive: false)
    private let cellular = NetworkConditions(isConstrained: false, isExpensive: true)
    private let lowData = NetworkConditions(isConstrained: true, isExpensive: false)
    private let lowDataOnCellular = NetworkConditions(isConstrained: true, isExpensive: true)

    @Test func enhancementIsNotSentInLowDataModeRegardlessOfSetting() {
        #expect(NetworkUsePolicy(conditions: lowData, sendsEnhancementOnExpensiveNetwork: true).enhancement == nil)
        #expect(NetworkUsePolicy(conditions: lowDataOnCellular, sendsEnhancementOnExpensiveNetwork: true).enhancement == nil)
    }

    @Test func enhancementOnExpensiveNetworkFollowsTheSetting() {
        #expect(NetworkUsePolicy(conditions: cellular, sendsEnhancementOnExpensiveNetwork: true).enhancement == .enhancement(onExpensiveNetwork: true))
        #expect(NetworkUsePolicy(conditions: cellular, sendsEnhancementOnExpensiveNetwork: false).enhancement == nil)
    }

    /// Wi-Fiでは、設定をオフにしていても送る。モバイル通信に変わったら、OSが送らないよう、設定をそのまま目的に持たせる。
    @Test func unmeteredNetworkSendsEnhancementCarryingTheSetting() {
        let purpose = NetworkUsePolicy(conditions: wifi, sendsEnhancementOnExpensiveNetwork: false).enhancement
        #expect(purpose == .enhancement(onExpensiveNetwork: false))
        #expect(purpose?.allowsExpensiveNetworkAccess == false)
        #expect(purpose?.allowsConstrainedNetworkAccess == false)
    }

    /// 先読みは、設定によらずWi-Fiでだけ送る。
    @Test func prefetchIsSentOnlyOnUnmeteredNetwork() {
        #expect(NetworkUsePolicy(conditions: wifi, sendsEnhancementOnExpensiveNetwork: false).prefetch == .prefetch)
        #expect(NetworkUsePolicy(conditions: cellular, sendsEnhancementOnExpensiveNetwork: true).prefetch == nil)
        #expect(NetworkUsePolicy(conditions: lowData, sendsEnhancementOnExpensiveNetwork: true).prefetch == nil)
    }

    @Test func onlyActionIsSentWhileAutomaticRequestsArePaused() {
        #expect(!RequestPurpose.action.isAutomatic)
        #expect(RequestPurpose.display.isAutomatic)
        #expect(RequestPurpose.enhancement(onExpensiveNetwork: true).isAutomatic)
        #expect(RequestPurpose.prefetch.isAutomatic)
    }

    @Test func actionAndDisplayAreSentOnAnyNetwork() {
        for purpose in [RequestPurpose.action, .display] {
            #expect(purpose.allowsExpensiveNetworkAccess)
            #expect(purpose.allowsConstrainedNetworkAccess)
        }
        #expect(!RequestPurpose.prefetch.allowsExpensiveNetworkAccess)
    }
}
