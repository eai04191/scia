import SciaCore
import SwiftUI

// 裸の`.task`を止める規則（`task_without_request_purpose`）の代わりに使う入口なので、ここだけは裸の`.task`で書く。
// swiftlint:disable task_without_request_purpose

extension View {
    /// `.task`を、通信の目的を`purpose`と名乗って始める。持ち主（`TaskScope`）を通らずに始める処理は、裸の`.task`ではなくこれで始める。
    func task(_ purpose: RequestPurpose, operation: @escaping @MainActor () async -> Void) -> some View {
        task {
            await RequestPurpose.$current.withValue(purpose) {
                await operation()
            }
        }
    }

    /// `id`が変わるたびに始め直す`.task`を、通信の目的を`purpose`と名乗って始める。
    func task<ID: Equatable>(_ purpose: RequestPurpose, id: ID, operation: @escaping @MainActor () async -> Void) -> some View {
        task(id: id) {
            await RequestPurpose.$current.withValue(purpose) {
                await operation()
            }
        }
    }

    /// 通信を送らない`.task`を始める。中で通信を送ると、名乗っていない通信として失敗する。
    func task(_: WithoutRequests, operation: @escaping @MainActor () async -> Void) -> some View {
        task {
            await RequestPurpose.$current.withValue(nil) {
                await operation()
            }
        }
    }

    /// `id`が変わるたびに始め直す、通信を送らない`.task`を始める。
    func task<ID: Equatable>(_: WithoutRequests, id: ID, operation: @escaping @MainActor () async -> Void) -> some View {
        task(id: id) {
            await RequestPurpose.$current.withValue(nil) {
                await operation()
            }
        }
    }
}

// swiftlint:enable task_without_request_purpose
