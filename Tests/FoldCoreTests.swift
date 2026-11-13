import Foundation

@main
struct FoldTests {
    static func main() {
    // Assertions carried over from kavishshahh/iphone-duo-animation native/Tests/FoldCoreTests.swift
    // (XCTest wrappers stripped so this runs with a plain swiftc). Run with ./tests.sh.

    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL \(what)") }
    }
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    // The working plane must be the identity: at rest nothing moves.
    for angle in [75.0, 90, 105, 135] {
        for u in [0.0, 0.2, 0.5, 0.9, 1] {
            for v in [0.0, 0.3, 0.7, 1] {
                guard let uv = FoldMath.sourceUV(u: u, v: v, angle: angle, workingAngle: angle, aspect: 1.6) else {
                    check(false, "nil uv angle=\(angle) u=\(u) v=\(v)"); continue
                }
                check(near(uv.0, u, 1e-10) && near(uv.1, v, 1e-10), "identity angle=\(angle) u=\(u) v=\(v) -> \(uv)")
            }
        }
    }

    // The hinge cannot move, whatever the angle.
    for angle in [18.0, 30, 60, 90, 105] {
        guard let uv = FoldMath.sourceUV(u: 0.5, v: 1, angle: angle, workingAngle: 105, aspect: 1.6) else {
            check(false, "hinge nil angle=\(angle)"); continue
        }
        check(near(uv.0, 0.5, 1e-10) && near(uv.1, 1, 1e-10), "hinge angle=\(angle) -> \(uv)")
    }

    // Bad tuning must not produce NaN on screen.
    var bad = FoldTuning()
    bad.workingAngle = .nan
    bad.fadeAngle = .infinity
    check(bad.validated.workingAngle == 105, "NaN workingAngle falls back")
    check(bad.validated.fadeAngle == 18, "infinite fadeAngle falls back")
    check(FoldMath.progress(angle: .nan, tuning: bad) == 0, "NaN angle gives zero progress")

    // A transparent overlay still covers the screen, so opacity is floored.
    var opacity = FoldTuning()
    check(opacity.validated.opacity == 1, "default opacity")
    opacity.opacity = 0
    check(opacity.validated.opacity == 0.15, "opacity 0 floored")
    opacity.opacity = -3
    check(opacity.validated.opacity == 0.15, "negative opacity floored")
    opacity.opacity = 4
    check(opacity.validated.opacity == 1, "opacity above 1 clamped")
    opacity.opacity = .nan
    check(opacity.validated.opacity == 1, "NaN opacity falls back")

    // Resting open is clear, closing folds, reopening clears.
    var openGate = FoldGate()
    let working = 133.0
    check(openGate.update(angle: working, workingAngle: working) == .idle, "open is idle")
    check(openGate.update(angle: working - 1, workingAngle: working) == .idle, "barely moved does not capture")
    check(openGate.update(angle: working - 10, workingAngle: working) == .captureRequested, "past threshold captures")
    openGate.captured()
    check(openGate.update(angle: working - 40, workingAngle: working) == .active, "captured is active")
    check(openGate.update(angle: working, workingAngle: working) == .idle, "reopening clears")

    // Smoothing must not depend on frame rate.
    var slow = 105.0
    var fast = 105.0
    for _ in 0..<30 { slow = FoldMath.smooth(current: slow, target: 30, dt: 1.0 / 30, response: 0.5) }
    for _ in 0..<120 { fast = FoldMath.smooth(current: fast, target: 30, dt: 1.0 / 120, response: 0.5) }
    check(near(slow, fast, 1e-9), "smoothing is frame-rate independent (\(slow) vs \(fast))")

    // A failed capture suppresses until the lid reopens.
    var failed = FoldGate()
    check(failed.update(angle: 103, workingAngle: 105) == .idle, "idle before threshold")
    check(failed.update(angle: 100, workingAngle: 105) == .captureRequested, "capture requested")
    failed.fail()
    check(failed.update(angle: 60, workingAngle: 105) == .suppressed, "failure suppresses")
    check(failed.update(angle: 105, workingAngle: 105) == .idle, "reopening clears suppression")
    check(failed.update(angle: 99, workingAngle: 105) == .captureRequested, "recapture after reopen")
    failed.captured()
    check(failed.state == .active, "recaptured is active")

    // A capture that lands after the lid reopened must not activate.
    var stale = FoldGate()
    _ = stale.update(angle: 70, workingAngle: 105)
    _ = stale.update(angle: 105, workingAngle: 105)
    stale.captured()
    check(stale.state == .idle, "stale capture ignored")

    if failures == 0 { print("fold core: all checks passed") } else { print("fold core: \(failures) failure(s)") }
    exit(failures == 0 ? 0 : 1)

    }
}
