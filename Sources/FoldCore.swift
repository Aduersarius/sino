import Foundation

// Reverse-engineered from kavishshahh/iphone-duo-animation (MIT): FoldCore/FoldMath.swift.
// Coordinates: hinge at origin, +y up, +z toward the viewer, folded panel height = 1.

struct FoldTuning: Equatable {
    var workingAngle: Double = 105
    var fadeAngle: Double = 18
    var perspective: Double = 0.8
    var frost: Double = 0.55
    var shade: Double = 0.35
    var response: Double = 0.72
    var opacity: Double = 1.0

    var validated: FoldTuning {
        var v = self
        v.workingAngle = foldClamp(workingAngle, 75, 135, 105)
        v.fadeAngle = foldClamp(fadeAngle, 8, 28, 18)
        v.perspective = foldClamp(perspective, 0, 1, 0.8)
        v.frost = foldClamp(frost, 0, 1, 0.55)
        v.shade = foldClamp(shade, 0, 1, 0.35)
        v.response = foldClamp(response, 0, 1, 0.72)
        // Floored above zero: a transparent overlay still swallows the screen.
        v.opacity = foldClamp(opacity, 0.15, 1, 1.0)
        return v
    }
}

func foldClamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
    v.isFinite ? min(hi, max(lo, v)) : fallback
}

enum FoldMath {
    /// 0 at the working angle, 1 by the fade angle.
    static func progress(angle: Double, tuning: FoldTuning) -> Double {
        let t = tuning.validated
        return foldClamp((t.workingAngle - angle) / (t.workingAngle - t.fadeAngle), 0, 1, 0)
    }

    /// Exponential approach: rate 12 + 34·response (~36.5 at the default), dt capped at 0.1 s.
    static func smooth(current: Double, target: Double, dt: Double, response: Double) -> Double {
        guard current.isFinite, target.isFinite else { return target.isFinite ? target : 105 }
        let elapsed = foldClamp(dt, 0, 0.1, 0)
        let rate = 12 + foldClamp(response, 0, 1, 0.72) * 34
        return current + (target - current) * (1 - exp(-rate * elapsed))
    }

    /// Inverse projection: trace a ray from the viewer through the moving panel and intersect
    /// the plane at the working angle. Returns source UV in 0…1, or nil where the ray misses.
    static func sourceUV(u: Double, v: Double, angle: Double, workingAngle: Double, aspect: Double,
                         eyeHeight: Double = 2.3, eyeDistance: Double = 2.6) -> (Double, Double)? {
        guard aspect > 0, [u, v, angle, workingAngle, aspect].allSatisfy({ $0.isFinite }) else { return nil }
        let a = angle * .pi / 180, w = workingAngle * .pi / 180
        let px = (u - 0.5) * aspect
        let py = (1 - v) * sin(a)
        let pz = (1 - v) * cos(a)
        let denominator = cos(w) * (py - eyeHeight) - sin(w) * (pz - eyeDistance)
        guard abs(denominator) > 0.00001 else { return nil }
        let ray = -(cos(w) * eyeHeight - sin(w) * eyeDistance) / denominator
        guard ray > 0 else { return nil }
        let x = ray * px
        let y = eyeHeight + ray * (py - eyeHeight)
        let z = eyeDistance + ray * (pz - eyeDistance)
        return (x / aspect + 0.5, 1 - (y * sin(w) + z * cos(w)))
    }
}

/// Hysteresis so a resting lid cannot re-trigger: capture at workingAngle − 4°, idle at − 0.5°.
struct FoldGate {
    enum State { case idle, captureRequested, active, suppressed }
    private(set) var state: State = .idle

    mutating func update(angle: Double, workingAngle: Double) -> State {
        guard angle.isFinite else { state = .suppressed; return state }
        if angle >= workingAngle - 0.5 { state = .idle }
        else if state == .idle && angle <= workingAngle - 4 { state = .captureRequested }
        return state
    }

    mutating func captured() { if state == .captureRequested { state = .active } }
    mutating func fail() { state = .suppressed }
    mutating func reset() { state = .idle }
}
