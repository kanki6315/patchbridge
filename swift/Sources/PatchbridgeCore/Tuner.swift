import Foundation

/// One pitch from the QC's tuner, as the nearest equal-tempered note and how far off it is.
public struct TunerPitch: Equatable {
    public static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    /// Within this many cents counts as in tune.
    public static let tolerance = 2.0
    public let hz: Double
    public let note: String
    public let octave: Int
    /// −50 (flat) to +50 (sharp) from `note`.
    public let cents: Double
    public var inTune: Bool { abs(cents) <= Self.tolerance }

    public init?(hz: Double, reference: Double = 440) {
        guard hz.isFinite, hz >= 20, hz <= 5000, reference > 0 else { return nil }
        let midi = 69 + 12 * log2(hz / reference)
        let nearest = midi.rounded()
        let number = Int(nearest)
        self.hz = hz
        note = Self.names[((number % 12) + 12) % 12]
        octave = Int((Double(number) / 12).rounded(.down)) - 1
        cents = (midi - nearest) * 100
    }
}

/// Steadies the QC's stream for display. The median of the last three readings means one stray
/// reading as a note starts or dies never moves the needle, and silence is shown as soon as the
/// QC stops sending (it sends nothing while no note rings).
public struct TunerTrack: Equatable {
    /// No reading for this long means the strings are quiet.
    public static let quietAfter: TimeInterval = 0.5
    private var recent: [Double] = []
    public private(set) var lastReading: TimeInterval = -.infinity
    public init() {}

    public mutating func add(hz: Double, at time: TimeInterval) {
        lastReading = time
        guard hz > 0 else { recent.removeAll(); return }
        recent.append(hz)
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
    }

    public func pitch(at time: TimeInterval) -> TunerPitch? {
        guard time - lastReading <= Self.quietAfter, !recent.isEmpty else { return nil }
        let sorted = recent.sorted()
        return TunerPitch(hz: sorted[sorted.count / 2])
    }
}
