import Foundation

/// Normalised biquad coefficients (a0 = 1), transposed direct form II.
struct BiquadCoefficients: Equatable {
    var b0, b1, b2, a1, a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ cookbook peaking EQ. Bands at or above Nyquist are bypassed.
    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard gainDB != 0, frequency < sampleRate * 0.49 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return BiquadCoefficients(b0: (1 + alpha * a) / a0,
                                  b1: -2 * cosW0 / a0,
                                  b2: (1 - alpha * a) / a0,
                                  a1: -2 * cosW0 / a0,
                                  a2: (1 - alpha / a) / a0)
    }
}
