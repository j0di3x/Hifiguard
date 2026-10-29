import XCTest
@testable import Hifiguard

final class DSPTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func sine(_ frequency: Double, amplitude: Float, seconds: Double = 1) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Runs `input` (mono, duplicated to both channels) through a renderer; returns the left channel.
    private func render(_ input: [Float], gains: [Float], limiter: Bool, rate: Double? = nil) -> [Float] {
        let parameters = EQParameters()
        parameters.store(gains: gains, limiter: limiter)
        let renderer = EQRenderer(sampleRate: rate ?? sampleRate, parameters: parameters)
        var left = input
        var right = input
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < input.count {
                    let count = min(512, input.count - offset)
                    renderer.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: count)
                    offset += count
                }
            }
        }
        return left
    }

    private func rmsOfSecondHalf(_ x: [Float]) -> Double {
        let tail = x[(x.count / 2)...]
        return sqrt(tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count))
    }

    private func gainDB(_ output: [Float], _ input: [Float]) -> Double {
        20 * log10(rmsOfSecondHalf(output) / rmsOfSecondHalf(input))
    }

    private func gains(band: Int, _ db: Float) -> [Float] {
        var g = EQBands.flat
        g[band] = db
        return g
    }

    func testBoostAtBandCentre() {
        let input = sine(1_000, amplitude: 0.1)
        let output = render(input, gains: gains(band: 5, 6), limiter: true)
        XCTAssertEqual(gainDB(output, input), 6, accuracy: 0.5)
    }

    func testCutAtBandCentre() {
        let input = sine(125, amplitude: 0.1)
        let output = render(input, gains: gains(band: 2, -12), limiter: true)
        XCTAssertEqual(gainDB(output, input), -12, accuracy: 0.5)
    }

    func testBoostLeavesDistantFrequenciesAlone() {
        let input = sine(8_000, amplitude: 0.1)
        let output = render(input, gains: gains(band: 0, 12), limiter: true)
        XCTAssertEqual(gainDB(output, input), 0, accuracy: 0.3)
    }

    func testFlatIsTransparentApartFromLatency() {
        let input = sine(440, amplitude: 0.5, seconds: 0.2)
        let latency = EQRenderer(sampleRate: sampleRate, parameters: EQParameters()).latencyFrames
        let output = render(input, gains: EQBands.flat, limiter: true)
        for i in latency..<input.count {
            XCTAssertEqual(output[i], input[i - latency], accuracy: 1e-6)
        }
    }

    func testLimiterKeepsPeaksBelowCeiling() {
        let input = sine(1_000, amplitude: 0.9)
        let output = render(input, gains: gains(band: 5, 12), limiter: true)
        let ceiling = Float(pow(10, -1.0 / 20))
        let peak = output.map(abs).max()!
        XCTAssertLessThanOrEqual(peak, ceiling + 1e-6)
        // Limited, not crushed: steady state sits close to the ceiling.
        XCTAssertGreaterThan(output[(output.count / 2)...].map(abs).max()!, ceiling * 0.9)
    }

    func testLimiterOffUsesPreampSoBoostCannotClip() {
        let input = sine(1_000, amplitude: 0.9)
        let output = render(input, gains: gains(band: 5, 12), limiter: false)
        XCTAssertEqual(gainDB(output, input), 0, accuracy: 0.5)
        XCTAssertLessThanOrEqual(output.map(abs).max()!, 1)
    }

    func testBandAboveNyquistIsBypassed() {
        let c = BiquadCoefficients.peaking(frequency: 16_000, q: EQBands.q, gainDB: 12, sampleRate: 22_050)
        XCTAssertEqual(c, .identity)
        let input = sine(1_000, amplitude: 0.1)
        let output = render(input, gains: gains(band: 9, 12), limiter: true, rate: 22_050)
        XCTAssertFalse(output.contains { !$0.isFinite })
    }

    func testParameterChangeIsPickedUp() {
        let parameters = EQParameters()
        let renderer = EQRenderer(sampleRate: sampleRate, parameters: parameters)
        var l = sine(1_000, amplitude: 0.1, seconds: 0.5)
        var r = l
        let input = l
        parameters.store(gains: gains(band: 5, -6), limiter: true)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                renderer.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count)
            }
        }
        XCTAssertEqual(gainDB(l, input), -6, accuracy: 0.5)
    }

    func testParameterPackingRoundTrip() {
        let parameters = EQParameters()
        let gains: [Float] = [-12, -6.5, 0, 0.5, 3, 12, -0.1, 7.5, -3, 11.5]
        parameters.store(gains: gains, limiter: false)
        let (low, high) = parameters.load()
        for (band, gain) in gains.enumerated() {
            XCTAssertEqual(EQParameters.gain(band, low: low, high: high), Double(gain), accuracy: 0.051)
        }
        XCTAssertFalse(EQParameters.limiterOn(high: high))
        parameters.store(gains: gains, limiter: true)
        XCTAssertTrue(EQParameters.limiterOn(high: parameters.load().high))
    }

    func testPresets() {
        XCTAssertGreaterThanOrEqual(EQPreset.all.count, 10)
        XCTAssertEqual(Set(EQPreset.all.map(\.name)).count, EQPreset.all.count)
        for preset in EQPreset.all {
            XCTAssertEqual(preset.gains.count, EQBands.count, preset.name)
            XCTAssertTrue(preset.gains.allSatisfy(EQBands.gainRange.contains), preset.name)
        }
    }
}
