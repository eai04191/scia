import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

struct InstanceResponseCacheTests {
    private static func response() throws -> InstanceResponseCache.Response {
        let url = try #require(URL(string: "https://example.social/api/v2/instance"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return InstanceResponseCache.Response(data: Data(#"{"version":"4.5.0"}"#.utf8), response: response, request: URLRequest(url: url))
    }

    /// 同じ読み込みを待つ呼び出しの1つを取り消すと、その呼び出しはその場で終わり、ほかの呼び出しのために読み続けて、読めた応答をキャッシュする。
    @Test func cancellingOneWaiterKeepsLoadingForOthers() async throws {
        let gate = Gate()
        let cache = InstanceResponseCache()
        let response = try Self.response()
        let loads = Mutex(0)
        let load: @Sendable () async throws -> InstanceResponseCache.Response = {
            loads.withLock { $0 += 1 }
            try await gate.wait()
            return response
        }
        let first = Task { try await cache.response(load: load) }
        let second = Task { try await cache.response(load: load) }
        try await waitUntil { cache.waiterCount == 2 && gate.waiterCount == 1 }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(gate.waiterCount == 1)
        gate.open()

        #expect(try await second.value.data == response.data)
        #expect(try await cache.response(load: load).data == response.data)
        #expect(loads.withLock { $0 } == 1)
    }

    /// 取り消されてから呼ばれたら、読み込みを始めない。
    @Test func cancelledCallerDoesNotStartLoad() async throws {
        let cache = InstanceResponseCache()
        let response = try Self.response()
        let loads = Mutex(0)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.response { loads.withLock { $0 += 1 }; return response }
        }.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(loads.withLock { $0 } == 0)
        #expect(cache.waiterCount == 0)
    }

    /// 目的の違う呼び出しは、同じ読み込みに合流せず、それぞれの目的で読む。
    @Test func callersWithDifferentPurposesDoNotShareLoad() async throws {
        let gate = Gate()
        let cache = InstanceResponseCache()
        let response = try Self.response()
        let purposes = Mutex<[RequestPurpose?]>([])
        let load: @Sendable () async throws -> InstanceResponseCache.Response = {
            purposes.withLock { $0.append(RequestPurpose.current) }
            try await gate.wait()
            return response
        }
        let display = Task { try await RequestPurpose.$current.withValue(.display) { try await cache.response(load: load) } }
        try await waitUntil { gate.waiterCount == 1 }
        let action = Task { try await RequestPurpose.$current.withValue(.action) { try await cache.response(load: load) } }
        try await waitUntil { gate.waiterCount == 2 }
        gate.open()

        #expect(try await display.value.data == response.data)
        #expect(try await action.value.data == response.data)
        #expect(purposes.withLock { $0 } == [.display, .action])
    }

    /// 待っている呼び出しがすべて取り消されたら読み込みも取り消し、次の呼び出しで再読み込みする。
    @Test func cancellingAllWaitersCancelsLoad() async throws {
        let gate = Gate()
        let cache = InstanceResponseCache()
        let response = try Self.response()
        let loads = Mutex(0)
        let load: @Sendable () async throws -> InstanceResponseCache.Response = {
            let attempt = loads.withLock { $0 += 1; return $0 }
            if attempt == 1 { try await gate.wait() }
            return response
        }
        let first = Task { try await cache.response(load: load) }
        let second = Task { try await cache.response(load: load) }
        try await waitUntil { cache.waiterCount == 2 && gate.waiterCount == 1 }

        first.cancel()
        second.cancel()
        #expect(gate.waiterCount == 0)
        await #expect(throws: CancellationError.self) { try await second.value }

        #expect(try await cache.response(load: load).data == response.data)
        #expect(loads.withLock { $0 } == 2)
    }
}
