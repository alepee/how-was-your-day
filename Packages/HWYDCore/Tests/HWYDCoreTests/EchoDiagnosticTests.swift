import XCTest
@testable import HWYDCore

final class EchoDiagnosticTests: XCTestCase {
    private func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5)
        }
    }
    func testDelayGainAndPolarity() {
        let system = noise(1500, seed: 42)
        for lag in [0, 123, 500] {
            let mic = system[(500 - lag)..<(1500 - lag)].map { -0.3 * $0 }
            let result = EchoDiagnostic.measure(microphone: mic, systemHistory: system, start: 7)
            XCTAssertEqual(result.status, "correlatedCandidate")
            XCTAssertEqual(result.delay!, Double(lag) / 1000, accuracy: 0.001)
            XCTAssertLessThan(result.residualRatio!, 1e-6)
            XCTAssertEqual(result.end, 8)
        }
    }
    func testStrongDoubleTalkAndUnrelatedAudioRemainUncertain() {
        let system = noise(1500, seed: 42)
        let local = noise(1000, seed: 99)
        let mixture = (0..<1000).map { system[400 + $0] * 0.5 + local[$0] }
        for mic in [local, mixture] {
            XCTAssertEqual(EchoDiagnostic.measure(microphone: mic, systemHistory: system, start: 0).status, "uncertain")
        }
    }
    func testSilenceAndInvalidInputs() {
        let silence = [Float](repeating: 0, count: 1500)
        for mic in [Array(silence.prefix(1000)), noise(1000, seed: 2), [Float.nan]] {
            XCTAssertEqual(EchoDiagnostic.measure(microphone: mic, systemHistory: silence, start: 0).status, "insufficientSignal")
        }
    }
    func testWeakDoubleTalkCanStillBeCorrelatedAndMustNeverAuthorizeRemoval() {
        let system = noise(1500, seed: 42), local = noise(1000, seed: 99)
        let mixture = (0..<1000).map { system[400 + $0] + 0.05 * local[$0] }
        XCTAssertEqual(EchoDiagnostic.measure(microphone: mixture, systemHistory: system, start: 0).status, "correlatedCandidate")
    }
}
