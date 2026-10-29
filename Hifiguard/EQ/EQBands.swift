import Foundation

enum EQBands {
    static let count = 10
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let q = 1.41
    static let gainRange: ClosedRange<Float> = -12...12
    static let flat = [Float](repeating: 0, count: count)

    static func label(_ band: Int) -> String {
        let f = frequencies[band]
        return f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))"
    }
}

struct EQPreset: Identifiable, Equatable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: EQBands.flat),
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Cut", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Vocal", gains: [-2, -2, -1, 0, 2, 3, 3, 2, 0, -1]),
        EQPreset(name: "Podcast", gains: [-6, -4, -1, 0, 1, 3, 3, 2, 0, -2]),
        EQPreset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        EQPreset(name: "Pop", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        EQPreset(name: "Electronic", gains: [5, 4, 2, 0, -2, 0, 1, 2, 4, 5]),
        EQPreset(name: "Jazz", gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        EQPreset(name: "Classical", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        EQPreset(name: "Loudness", gains: [6, 4, 1, 0, -1, 0, 0, 1, 4, 6]),
    ]
}
