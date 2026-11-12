import Foundation

struct MediaKeySequence {
    private var pressed: [Int: Bool] = [:]

    mutating func press(_ code: Int, consume: Bool) -> Bool {
        if let previous = pressed[code] { return previous }
        pressed[code] = consume
        return consume
    }

    mutating func release(_ code: Int) -> Bool { pressed.removeValue(forKey: code) ?? false }
    mutating func reset() { pressed.removeAll() }
}

enum BrightnessStepping {
    static func target(from current: Float, delta: Float, step: Float) -> Float {
        guard current.isFinite, delta.isFinite, step.isFinite else { return 0 }
        let level = max(0, min(1, current))
        guard delta != 0, step > 0 else { return max(0, min(1, level + delta)) }
        let count = max(1, (abs(delta) / step).rounded())
        let position = level / step
        let grid = delta > 0 ? floor(position + 0.01) + count : ceil(position - 0.01) - count
        return max(0, min(1, grid * step))
    }
}
