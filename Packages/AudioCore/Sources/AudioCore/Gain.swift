/// A finite attenuation value. Unity restores the source's normal volume.
public struct Gain: Equatable, Sendable {
    /// The normalized gain, in the inclusive range zero to one.
    public let value: Float

    /// A non-finite value fails open at unity.
    public init(_ value: Float) {
        self.value = value.isFinite ? min(max(value, 0), 1) : 1
    }

    /// The source's unmodified volume.
    public static let unity = Gain(1)
}

/// One linear ramp advances by frame, so every channel receives the same gain.
struct GainRamp {
    let start: Float
    let step: Float

    init(from start: Float, to end: Float, frames: Int) {
        self.start = start
        self.step = frames > 0 ? (end - start) / Float(frames) : 0
    }

    @inline(__always)
    func value(after frames: Int) -> Float {
        start + step * Float(frames)
    }
}
