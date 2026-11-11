import Testing
@testable import CloudSync

@Suite("Backoff")
struct BackoffTests {
    @Test func theCeilingDoublesFromOneSecondToFiveMinutes() {
        #expect((0...10).map { Backoff.ceiling(attempt: $0) } == [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(Backoff.ceiling(attempt: 1_000) == 300)
        #expect(Backoff.ceiling(attempt: -3) == 1)
    }

    @Test func fullJitterSpansZeroToTheCeiling() {
        #expect(Backoff.delay(attempt: 3, random: 0) == 0)
        #expect(Backoff.delay(attempt: 3, random: 0.5) == 4)
        #expect(Backoff.delay(attempt: 3, random: 1) == 8)
        #expect(Backoff.delay(attempt: 3, random: 7) == 8)
        #expect(Backoff.delay(attempt: 3, random: -1) == 0)
    }

    @Test func randomDelaysStayInsideTheWindow() {
        for attempt in 0..<12 {
            for _ in 0..<50 {
                let delay = Backoff.delay(attempt: attempt)
                #expect(delay >= 0 && delay <= Backoff.ceiling(attempt: attempt))
            }
        }
    }

    @Test func aHealthyConnectionResetsAfterAMinute() {
        #expect(Backoff.healthyAfter == 60)
    }
}
