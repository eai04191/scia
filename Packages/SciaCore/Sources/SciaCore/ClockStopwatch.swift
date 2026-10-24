/// `clock`で、今から経った長さを返す関数。時計ごとに「今」の型が違うため、受け取った時計の種類によらずに、期限や残りの長さを測るのに使う。
public func stopwatch(on clock: any Clock<Duration>) -> @Sendable () -> Duration {
    start(clock)
}

private func start<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
    let started = clock.now
    return { started.duration(to: clock.now) }
}
