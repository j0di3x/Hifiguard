import Foundation

/// Stereo-linked look-ahead peak limiter.
///
/// Required gain per sample → sliding minimum over `lookahead + 1` samples → moving average over
/// `lookahead` samples, applied to audio delayed by `lookahead`. The average is never above the gain a
/// peak needs by the time that peak leaves the delay line, so the attack is smooth and still catches it.
/// Everything is allocated in `init`; `process` never allocates or locks.
final class Limiter {
    let lookahead: Int
    let ceiling: Double
    private let holdLength: Int
    private let releaseCoef: Double

    private let delayL: UnsafeMutablePointer<Double>
    private let delayR: UnsafeMutablePointer<Double>
    private var delayPos = 0

    // Monotonic deque (ring buffer) for the sliding minimum.
    private let dequeValue: UnsafeMutablePointer<Double>
    private let dequeIndex: UnsafeMutablePointer<Int>
    private var dequeHead = 0
    private var dequeCount = 0

    private let box: UnsafeMutablePointer<Double>
    private var boxPos = 0
    private var boxSum: Double

    private var gain = 1.0
    private var n = 0

    init(sampleRate: Double, lookaheadSeconds: Double = 0.005, releaseSeconds: Double = 0.08, ceilingDB: Double = -1) {
        lookahead = max(1, Int(sampleRate * lookaheadSeconds))
        holdLength = lookahead + 1
        ceiling = pow(10, ceilingDB / 20)
        releaseCoef = 1 - exp(-1 / (releaseSeconds * sampleRate))

        delayL = .allocate(capacity: lookahead)
        delayR = .allocate(capacity: lookahead)
        delayL.initialize(repeating: 0, count: lookahead)
        delayR.initialize(repeating: 0, count: lookahead)
        dequeValue = .allocate(capacity: holdLength)
        dequeIndex = .allocate(capacity: holdLength)
        dequeValue.initialize(repeating: 1, count: holdLength)
        dequeIndex.initialize(repeating: 0, count: holdLength)
        box = .allocate(capacity: lookahead)
        box.initialize(repeating: 1, count: lookahead)
        boxSum = Double(lookahead)
    }

    deinit {
        delayL.deallocate()
        delayR.deallocate()
        dequeValue.deallocate()
        dequeIndex.deallocate()
        box.deallocate()
    }

    /// Delays the frame by `lookahead`; applies gain reduction only when `enabled`.
    @inline(__always)
    func process(_ l: inout Double, _ r: inout Double, enabled: Bool) {
        let peak = max(abs(l), abs(r))
        let required = peak > ceiling ? ceiling / peak : 1

        // Sliding minimum over the last `holdLength` samples.
        while dequeCount > 0 && dequeIndex[dequeHead] <= n - holdLength {
            dequeHead = (dequeHead + 1) % holdLength
            dequeCount -= 1
        }
        while dequeCount > 0 && dequeValue[(dequeHead + dequeCount - 1) % holdLength] >= required {
            dequeCount -= 1
        }
        let back = (dequeHead + dequeCount) % holdLength
        dequeValue[back] = required
        dequeIndex[back] = n
        dequeCount += 1
        let held = dequeValue[dequeHead]

        boxSum += held - box[boxPos]
        box[boxPos] = held
        boxPos = (boxPos + 1) % lookahead
        let smoothed = boxSum / Double(lookahead)

        // Instant attack (already smoothed by the look-ahead window), exponential release.
        gain = smoothed < gain ? smoothed : gain + (smoothed - gain) * releaseCoef

        let dl = delayL[delayPos]
        let dr = delayR[delayPos]
        delayL[delayPos] = l
        delayR[delayPos] = r
        delayPos = (delayPos + 1) % lookahead
        n &+= 1

        if enabled {
            l = min(max(dl * gain, -ceiling), ceiling)
            r = min(max(dr * gain, -ceiling), ceiling)
        } else {
            l = dl
            r = dr
        }
    }
}
