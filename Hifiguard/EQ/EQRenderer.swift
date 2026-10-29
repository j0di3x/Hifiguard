import CoreAudio
import Dispatch
import Synchronization

/// Lock-free hand-off of EQ settings from the main thread to the audio thread.
/// Gains are packed as Int8 tenths of a dB: bands 0–7 in `low`, bands 8–9 and flags in `high`.
/// A torn read across the two words lasts at most one IO cycle and is corrected on the next.
final class EQParameters: Sendable {
    private let low = Atomic<UInt64>(0)
    private let high = Atomic<UInt64>(0)
    private static let limiterBit: UInt64 = 1 << 16

    func store(gains: [Float], limiter: Bool) {
        var lo: UInt64 = 0
        var hi: UInt64 = limiter ? Self.limiterBit : 0
        for (band, gain) in gains.prefix(EQBands.count).enumerated() {
            let clamped = min(max(gain, EQBands.gainRange.lowerBound), EQBands.gainRange.upperBound)
            let byte = UInt64(UInt8(bitPattern: Int8((clamped * 10).rounded())))
            if band < 8 { lo |= byte << (8 * band) } else { hi |= byte << (8 * (band - 8)) }
        }
        low.store(lo, ordering: .releasing)
        high.store(hi, ordering: .releasing)
    }

    @inline(__always)
    func load() -> (low: UInt64, high: UInt64) {
        (low.load(ordering: .acquiring), high.load(ordering: .acquiring))
    }

    @inline(__always)
    static func gain(_ band: Int, low: UInt64, high: UInt64) -> Double {
        let word = band < 8 ? low : high
        let shift = 8 * (band < 8 ? band : band - 8)
        return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: word >> UInt64(shift)))) / 10
    }

    @inline(__always)
    static func limiterOn(high: UInt64) -> Bool { high & limiterBit != 0 }
}

/// The real-time part: 10 peaking biquads per channel, then the limiter.
/// Created on the main thread; after `start`, only the IO thread calls `render`/`process`.
final class EQRenderer: @unchecked Sendable {
    static let chunk = 1024

    let sampleRate: Double
    var latencyFrames: Int { limiter.lookahead }
    /// Fired once, from the IO thread, when the tap first delivers a non-silent sample.
    var signal: DispatchSourceUserDataOr?

    private let parameters: EQParameters
    private let limiter: Limiter
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let frequencies: UnsafeMutablePointer<Double>
    /// [channel][band][z1, z2]
    private let state: UnsafeMutablePointer<Double>
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private var lastLow: UInt64 = .max
    private var lastHigh: UInt64 = .max
    private var preamp = 1.0
    private var limiterOn = true
    private var signalReported = false
    private let outputEnabled = Atomic<Bool>(false)

    init(sampleRate: Double, parameters: EQParameters) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        limiter = Limiter(sampleRate: sampleRate)
        coefficients = .allocate(capacity: EQBands.count)
        coefficients.initialize(repeating: .identity, count: EQBands.count)
        frequencies = .allocate(capacity: EQBands.count)
        frequencies.initialize(from: EQBands.frequencies, count: EQBands.count)
        state = .allocate(capacity: 2 * EQBands.count * 2)
        state.initialize(repeating: 0, count: 2 * EQBands.count * 2)
        scratchL = .allocate(capacity: Self.chunk)
        scratchR = .allocate(capacity: Self.chunk)
    }

    deinit {
        coefficients.deallocate()
        frequencies.deallocate()
        state.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
    }

    /// Until enabled, `render` outputs silence (the original audio still plays, unmuted).
    func setOutputEnabled(_ enabled: Bool) { outputEnabled.store(enabled, ordering: .releasing) }
    var isOutputEnabled: Bool { outputEnabled.load(ordering: .acquiring) }

    /// IO proc body. Input: the tap is the last input stream. Output: L/R to the first two channels.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var outChannels = 0
        var outFrames = Int.max
        for buffer in outList where buffer.mData != nil && buffer.mNumberChannels > 0 {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            outChannels += Int(buffer.mNumberChannels)
            outFrames = min(outFrames, Int(buffer.mDataByteSize) / (4 * Int(buffer.mNumberChannels)))
        }

        var tap: AudioBuffer?
        for buffer in inList where buffer.mData != nil && buffer.mNumberChannels > 0 { tap = buffer }
        guard let tap, let tapData = tap.mData?.assumingMemoryBound(to: Float.self) else { return }
        let tapChannels = Int(tap.mNumberChannels)
        let inFrames = Int(tap.mDataByteSize) / (4 * tapChannels)

        if !signalReported {
            for i in 0..<(inFrames * tapChannels) where tapData[i] != 0 {
                signalReported = true
                signal?.or(data: 1)
                break
            }
        }
        guard outChannels > 0, outFrames != .max, isOutputEnabled else { return }

        let frames = min(inFrames, outFrames)
        var offset = 0
        while offset < frames {
            let count = min(Self.chunk, frames - offset)
            for f in 0..<count {
                let base = (offset + f) * tapChannels
                scratchL[f] = tapData[base]
                scratchR[f] = tapData[base + (tapChannels > 1 ? 1 : 0)]
            }
            process(left: scratchL, right: scratchR, frames: count)

            var channelBase = 0
            for buffer in outList where buffer.mData != nil && buffer.mNumberChannels > 0 {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(buffer.mNumberChannels)
                for c in 0..<channels {
                    let global = channelBase + c
                    guard global < 2 else { break }
                    for f in 0..<count {
                        let value = outChannels == 1 ? (scratchL[f] + scratchR[f]) * 0.5
                                  : (global == 0 ? scratchL[f] : scratchR[f])
                        data[(offset + f) * channels + c] = value
                    }
                }
                channelBase += channels
            }
            offset += count
        }
    }

    /// In-place stereo processing. Picks up new parameters at block start.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        updateParametersIfNeeded()
        let bands = EQBands.count
        for f in 0..<frames {
            var l = Double(left[f]) * preamp
            var r = Double(right[f]) * preamp
            for band in 0..<bands {
                let c = coefficients[band]
                let sl = state + band * 2
                let yl = c.b0 * l + sl[0]
                sl[0] = c.b1 * l - c.a1 * yl + sl[1]
                sl[1] = c.b2 * l - c.a2 * yl
                l = yl
                let sr = state + (bands + band) * 2
                let yr = c.b0 * r + sr[0]
                sr[0] = c.b1 * r - c.a1 * yr + sr[1]
                sr[1] = c.b2 * r - c.a2 * yr
                r = yr
            }
            limiter.process(&l, &r, enabled: limiterOn)
            left[f] = Float(l)
            right[f] = Float(r)
        }
    }

    private func updateParametersIfNeeded() {
        let (low, high) = parameters.load()
        guard low != lastLow || high != lastHigh else { return }
        lastLow = low
        lastHigh = high
        limiterOn = EQParameters.limiterOn(high: high)
        var maxBoost = 0.0
        for band in 0..<EQBands.count {
            let gain = EQParameters.gain(band, low: low, high: high)
            maxBoost = max(maxBoost, gain)
            coefficients[band] = .peaking(frequency: frequencies[band], q: EQBands.q,
                                          gainDB: gain, sampleRate: sampleRate)
        }
        // Without the limiter, pull the level down so the biggest boost cannot clip.
        preamp = limiterOn ? 1 : pow(10, -maxBoost / 20)
    }
}
