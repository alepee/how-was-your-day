import Foundation

/// Experimental measurement, never an instruction to remove speech.
public struct EchoWindow: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var status: String
    public var delay: Double?
    public var correlation: Double?
    public var residualRatio: Double?
}

public enum EchoDiagnostic {
    /// Both arrays are 1 kHz mono PCM. System includes 500 ms of preceding history.
    /// Samples before session start must be zero padded by the caller.
    public static func measure(microphone: [Float], systemHistory: [Float], start: Double) -> EchoWindow {
        var output = EchoWindow(start: start, end: start + Double(microphone.count) / 1000,
                                status: "insufficientSignal", delay: nil, correlation: nil, residualRatio: nil)
        guard microphone.count >= 500, systemHistory.count == microphone.count + 500,
              microphone.allSatisfy({ $0.isFinite }), systemHistory.allSatisfy({ $0.isFinite }) else { return output }
        let count = Double(microphone.count)
        let mean = microphone.reduce(0) { $0 + Double($1) } / count
        let mic = microphone.map { Double($0) - mean }
        let energy = mic.reduce(0) { $0 + $1 * $1 }
        guard energy / count >= 1e-6 else { return output }
        var best = 0.0
        var bestLag: Int?
        for lag in 0...500 {
            let offset = 500 - lag
            var sum = 0.0, squared = 0.0, dot = 0.0
            for index in mic.indices {
                let value = Double(systemHistory[offset + index])
                sum += value; squared += value * value; dot += value * mic[index]
            }
            let systemEnergy = max(0, squared - sum * sum / count)
            guard systemEnergy / count >= 1e-6 else { continue }
            let correlation = min(1, abs(dot) / sqrt(systemEnergy * energy))
            if bestLag == nil || correlation > best { best = correlation; bestLag = lag }
        }
        guard let bestLag else { return output }
        output.correlation = best
        output.delay = Double(bestLag) / 1000
        output.residualRatio = max(0, 1 - best * best)
        output.status = best >= 0.95 ? "correlatedCandidate" : "uncertain"
        return output
    }
}
