import Foundation
@main struct MediaControlChecks {
    static func main() {
        var keys = MediaKeySequence()
        for _ in 0..<20 {
            assert(keys.press(0, consume: true))
            assert(keys.press(0, consume: false))
            assert(!keys.press(1, consume: false))
            assert(!keys.press(1, consume: true))
            assert(keys.release(0))
            assert(!keys.release(0))
            assert(!keys.release(1))
            assert(keys.press(2, consume: true))
            keys.reset()
            assert(!keys.release(2))
        }
        let step: Float = 1 / 16
        assert(BrightnessStepping.target(from: 0.51, delta: -step, step: step) == 0.5)
        assert(BrightnessStepping.target(from: 0.49, delta: step, step: step) == 0.5)
        assert(BrightnessStepping.target(from: 0.5, delta: step, step: step) == 0.5625)
        assert(BrightnessStepping.target(from: 0.49999, delta: step, step: step) == 0.5625)
        assert(BrightnessStepping.target(from: 0.50001, delta: -step, step: step) == 0.4375)
        assert(BrightnessStepping.target(from: 0.51, delta: -1/64, step: 1/64) == 0.5)
        assert(BrightnessStepping.target(from: 0.25, delta: 2 * step, step: step) == 0.375)
        assert(BrightnessStepping.target(from: 0.99, delta: step, step: step) == 1)
        assert(BrightnessStepping.target(from: 0, delta: -step, step: step) == 0)
        print("PASS: media key pairs/repeats/source changes, 20 resets, keyboard brightness grids and limits")
    }
}
