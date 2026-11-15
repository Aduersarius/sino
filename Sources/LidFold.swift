import AppKit

/// Drives the lid fold while Awake is on. Rendering is sensor-driven: one frame per HID report
/// (~30 Hz), nothing at all while the lid is still. Ported geometry from
/// kavishshahh/iphone-duo-animation (MIT), behaviour adapted.
func foldLog(_ message: String) {
    NSLog("lid fold: %@", message)
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Sino-fold.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

final class LidFold {
    static let shared = LidFold()

    private let overlay = FoldOverlay()
    private var gate = FoldGate()
    private var enabled = false
    private var capturing = false
    private var gestureID = UUID()
    private var shownAngle = 105.0
    private var lastReading = Date.distantPast
    private var nilSince: Date?
    private var nilDrop: DispatchWorkItem?
    private var idleHide: DispatchWorkItem?
    private var framesRunning = false
    private var reportInterval: Double = 0
    private var revealing = false
    private var revealDeadline = Date.distantPast
    private var lastChangeAt = Date.distantPast
    private var lastDistinctAngle = -1.0
    private var dupReports = 0
    private var changeCount = 0
    private var targetAngle: Double = 105
    private var lastFrame = Date()
    private var lastReport = Date.distantPast
    private var frameCount = 0
    private var drawCount = 0
    private var gestureStart = Date()
    private var stagedShots: [(image: CGImage, screen: NSScreen)]?
    private var stagedAt = Date.distantPast
    private var staging = false
    private var lastLoggedState: FoldGate.State = .idle
    private var armedSeenOpen = false
    private var loggedWaiting = false
    private var lowPowerApplied = false
    private var peakAngle: Double = 0
    private var troughAngle: Double = 0
    private var lastAngle: Double = 0
    private var risingAt = Date.distantPast

    private var tuning: FoldTuning {
        var t = FoldTuning()
        t.workingAngle = Prefs.shared.foldAngle
        t.frost = Prefs.shared.foldBlur
        return t
    }
    private var working: Double { tuning.validated.workingAngle }

    private init() {}

    var isArmed: Bool { enabled }

    func start() {
        guard !enabled, Prefs.shared.foldMode != "off" else { return }
        enabled = true
        armedSeenOpen = false
        loggedWaiting = false
        peakAngle = 0
        troughAngle = 999
        risingAt = .distantPast
        gate.reset()
        frameCount = 0
        drawCount = 0
        gestureStart = Date()
        foldLog("armed, fold starts at \(Int(working)) deg")
        if !Prefs.shared.foldBlurOnly {
            DesktopCapture.warm()
            FoldOverlay.prewarm()
        }
        if DesktopCapture.hasBuiltInDisplay, !Prefs.shared.foldBlurOnly { LiveDesktop.shared.start() }
        LidSensor.shared.onChange = { [weak self] angle in self?.receive(angle) }
        LidSensor.shared.start()
    }

    func stop() {
        if lowPowerApplied {
            lowPowerApplied = false
            App.shared.setLowPowerMode(false)
        }
        enabled = false
        LiveDesktop.shared.stop()
        staging = false
        cancelTimers()
        LidSensor.shared.onChange = nil
        LidSensor.shared.stop()
        overlay.hide()
    }

    private func cancelTimers() {
        nilDrop?.cancel(); nilDrop = nil
        idleHide?.cancel(); idleHide = nil
        nilSince = nil
    }

    // MARK: Sensor

    private func receive(_ reading: Double?) {
        guard enabled else { return }
        lastReading = Date()

        guard let angle = reading else {
            // A shut lid stops answering. Keep the frozen frame: tearing down here is what made
            // every open animation disappear.
            gate.fail()
            if nilSince == nil {
                nilSince = Date()
                foldLog("sensor silent at \(Int(shownAngle)) deg, holding the fold")
                scheduleNilDrop(after: 10)
            }
            return
        }
        if nilSince != nil {
            nilSince = nil
            nilDrop?.cancel(); nilDrop = nil
            foldLog("sensor back at \(Int(angle)) deg")
            // A silent stretch leaves the gate suppressed. If the lid is already back in the
            // open range, allow a fresh capture instead of waiting for the working angle —
            // otherwise the next close is silently ignored.
            if angle >= working - 4 { gate.reset() }
        }

        // A start angle at or above the lid's resting angle would fold the moment Awake arms.
        if !armedSeenOpen {
            guard angle >= working - 0.5 else {
                if !loggedWaiting {
                    loggedWaiting = true
                    foldLog("waiting: lid at \(Int(angle)) deg, fold starts at \(Int(working)) deg")
                }
                return
            }
            armedSeenOpen = true
            gate.reset()
        }

        // The signal's real rate is the interval between *changed* readings; polling faster only
        // adds duplicates. This interval is also the only honest input for the adaptive ease.
        let nowReport = Date()
        if angle != lastDistinctAngle {
            if lastChangeAt != .distantPast {
                let gap = nowReport.timeIntervalSince(lastChangeAt)
                reportInterval = reportInterval == 0 ? gap : reportInterval * 0.7 + gap * 0.3
            }
            lastDistinctAngle = angle
            lastChangeAt = nowReport
            changeCount += 1
        } else {
            dupReports += 1
        }
        lastReport = nowReport
        // While revealing, the target is the working angle on purpose; a live report must not
        // re-aim it or the ease never reaches the identity frame.
        if !revealing, abs(angle - targetAngle) >= Prefs.shared.foldJitter { targetAngle = angle }
        startFrames()

        if angle > lastAngle + 0.2 { risingAt = Date() }
        lastAngle = angle
        if angle > peakAngle { peakAngle = angle }
        if angle < troughAngle { troughAngle = angle }

        if Prefs.shared.lowPowerOnLidClose {
            let closed = angle <= working - 4
            if closed != lowPowerApplied {
                lowPowerApplied = closed
                foldLog(closed ? "lid closed: Low Power Mode on" : "lid open: Low Power Mode off")
                App.shared.setLowPowerMode(closed)
            }
        }

        let state = gate.update(angle: angle, workingAngle: working)
        if state != lastLoggedState {
            lastLoggedState = state
            foldLog("gate \(state) at \(String(format: "%.1f", angle)) deg, working \(Int(working))")
        }

        // Snapshot before the threshold: ShareableContent plus the capture costs 80-170 ms, which
        // is the lag at the start of the fold. Staging it a few degrees early makes the handover
        // immediate; the stale window is ~200 ms of a closing lid.
        if !overlay.isShowing, !staging, stagedShots == nil, angle <= working - 0.3 {
            stage()
        }

        switch state {
        case .captureRequested:
            capture()
            if blurFold.isShowing { blurFold.update(angle: angle, working: working, tuning: tuning) }
        case .idle:
            stagedShots = nil
            staging = false
            if showing { reveal() }
        case .active, .suppressed:
            break
        }

        if blurFold.isShowing, !revealing {
            blurFold.update(angle: angle, working: working, tuning: tuning)
        }

        guard showing else { return }

        // A start angle above the lid's rest means the idle branch never fires; release once the
        // lid has genuinely opened and stopped.
        let sinceRise = Date().timeIntervalSince(risingAt)
        let settledOpen = sinceRise > 0.3 && angle >= troughAngle + 3 && angle >= peakAngle - 0.75
        if settledOpen, angle < working - 0.5 {
            foldLog("lid settled open at \(Int(angle)) deg, revealing desktop")
            reveal()
        }
        // No direct draw here: the 60 Hz pump owns shownAngle and easing, fed by targetAngle.
    }

    /// 60 Hz interpolation between sensor reports, only while the lid is moving. The timer stops
    /// once the angle has converged, so a resting lid costs nothing.
    private func startFrames() {
        // Blur has no per-frame work: the compositor blends it and only the opacity changes.
        guard overlay.isShowing, !framesRunning else { return }
        framesRunning = true
        lastFrame = Date()
        overlay.startFrameLink { [weak self] in self?.frame() }
    }

    private func stopFrames() {
        guard framesRunning else { return }
        framesRunning = false
        overlay.stopFrameLink()
    }

    private func frame() {
        guard showing else { stopFrames(); return }
        frameCount += 1
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        lastFrame = now
        // Ease over half the measured report interval (Bendable's shape): bounds the lag to about
        // half a degree at any lid speed, and cannot overshoot. A stall snaps instead of sweeping.
        var next = targetAngle
        if dt <= 0.25 {
            let ease = min(0.25, max(0.012, reportInterval * 0.5))
            let alpha = 1 - exp(-dt / ease)
            next = shownAngle + (targetAngle - shownAngle) * alpha
        }
        if revealing {
            if abs(next - working) < 0.8 || now > revealDeadline {
                revealing = false
                shownAngle = working
                apply(working)
                stopFrames()
                hideSoon(0.05)
            } else if abs(next - shownAngle) > 0.01 {
                shownAngle = next
                apply(next)
                drawCount += 1
            }
            return
        }
        if abs(next - shownAngle) > 0.01 {
            shownAngle = next
            apply(next)
            drawCount += 1
        }
        if abs(next - targetAngle) < 0.05, now.timeIntervalSince(lastReport) > 0.25 {
            stopFrames()
        }
    }

    private func render(_ angle: Double) {
        guard showing else { return }
        shownAngle = angle
        apply(angle)
    }

    /// The blur mode redraws nothing between reports: the compositor owns the frost, so a new
    /// angle is just a new opacity.
    private func apply(_ angle: Double) {
        if blurFold.isShowing {
            blurFold.update(angle: angle, working: working, tuning: tuning)
        } else {
            overlay.update(angle: angle, tuning: tuning)
        }
    }

    /// A shut lid can keep the sensor silent for minutes, and the frozen frame is the only thing
    /// the next open has to unfold — so silence alone must not discard it. It is only a problem
    /// when the display is awake, because then the panel sits over a live desktop.
    private func scheduleNilDrop(after delay: TimeInterval) {
        nilDrop?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.nilSince != nil else { return }
            // Awake holds a PreventUserIdleDisplaySleep assertion, so CGDisplayIsAsleep is 0
            // whenever the fold is armed — the lid angle is the honest signal. A sensor that dies
            // with the lid shut is expected and the frame must survive it; one that dies with the
            // lid open leaves a frozen panel over a live desktop, so drop.
            if self.lastAngle < 30 {
                self.scheduleNilDrop(after: 5)
                return
            }
            foldLog("sensor silent with the lid open at \(Int(self.lastAngle)) deg, dropping the fold")
            self.teardown()
        }
        nilDrop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reveal() {
        guard idleHide == nil, !revealing else { return }
        if let until = previewingUntil, Date() < until { return }
        // Blur has no frame of its own to ease back: the compositor is already showing the live
        // desktop, so dropping it is the whole reveal.
        if blurFold.isShowing {
            shownAngle = working
            hideSoon(0.04)
            return
        }
        if abs(shownAngle - working) < 1.0 {
            stopFrames()
            hideSoon(0.04)
            return
        }
        // Snap-rendering the identity here jumped the fold the whole way on a fast open: the
        // sensor can report 80 -> 110 in one step while the drawn angle is still far behind.
        // Ease to it over a few frames instead, then hide.
        revealing = true
        revealDeadline = Date().addingTimeInterval(0.3)
        targetAngle = working
        startFrames()
    }

    private func hideSoon(_ delay: TimeInterval) {
        idleHide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.teardown() }
        idleHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Capture

    private func stage() {
        guard !Prefs.shared.foldBlurOnly, DesktopCapture.hasBuiltInDisplay else { return }
        if NSScreen.screens.count <= 1 {
            staging = true          // the persistent stream supplies the frame; nothing to stage
            return
        }
        staging = true
        Task { @MainActor in
            defer { staging = false }
            do {
                let shots = try await DesktopCapture.snapshots()
                guard !shots.isEmpty, enabled, !overlay.isShowing else { return }
                stagedShots = shots
                stagedAt = Date()
                foldLog("staged \(shots.count) display(s) ahead of the threshold")
            } catch {
                foldLog("staging failed: \(error.localizedDescription)")
            }
        }
    }

    private let blurFold = BlurFold()
    private var previewingUntil: Date?
    private var showing: Bool { overlay.isShowing || blurFold.isShowing }

    private func capture() {
        guard !capturing else { return }
        // Blur mode never reads the screen: the window server blurs whatever is behind the panel.
        if Prefs.shared.foldBlurOnly {
            if blurFold.isShowing { return }
            revealing = false
            idleHide?.cancel()
            idleHide = nil
            shownAngle = working
            targetAngle = working
            blurFold.show(angle: working, working: working, tuning: tuning)
            gate.captured()
            troughAngle = working
            lastAngle = troughAngle
            risingAt = .distantPast
            gestureStart = Date()
            foldLog("blur fold on \(NSScreen.screens.count) display(s), no capture")
            return
        }
        // The blur mode never reads the screen: the compositor frosts the live desktop instead.

        if let shots = stagedShots, Date().timeIntervalSince(stagedAt) < 0.8 {
            stagedShots = nil
            show(shots: shots, stagingMs: Date().timeIntervalSince(stagedAt) * 1000)
            return
        }
        stagedShots = nil
        // The persistent stream already holds a frame; use it before paying for a snapshot.
        let liveStart = Date()
        if let image = LiveDesktop.shared.freshImage(maxAge: 0.4),
           let screen = NSScreen.screens.first {
            // CIContext → CGImage at backing size is not free; log it rather than reporting 0.
            let liveMs = Date().timeIntervalSince(liveStart) * 1000
            foldLog(String(format: "live frame %.0f ms for %dx%d", liveMs, image.width, image.height))
            show(shots: [(image: image, screen: screen)], stagingMs: liveMs)
            return
        }
        guard DesktopCapture.hasBuiltInDisplay else {
            foldLog("no built-in display awake, skipping the fold")
            gate.fail()
            return
        }
        capturing = true
        let id = UUID()
        gestureID = id
        idleHide?.cancel(); idleHide = nil
        Task { @MainActor in
            defer { capturing = false }
            do {
                let start = Date()
                let shots = try await DesktopCapture.snapshots()
                let captureMs = Date().timeIntervalSince(start) * 1000
                guard gestureID == id, enabled, gate.state == .captureRequested, !shots.isEmpty else { return }
                show(shots: shots, stagingMs: captureMs)
            } catch {
                foldLog("capture failed: \(error.localizedDescription)")
                gate.fail()
            }
        }
    }

    private func show(shots: [(image: CGImage, screen: NSScreen)], stagingMs: Double) {
        // A close during the reveal window must not inherit its phase: `revealing` would ease to
        // the working angle and hide the panel on the first pump frame.
        revealing = false
        idleHide?.cancel()
        idleHide = nil
        shownAngle = working
        targetAngle = working
        let showStart = Date()
        if Prefs.shared.foldBlurOnly {
            blurFold.show(angle: working, working: working, tuning: tuning)
        } else {
        do {
            try overlay.show(snapshots: shots, angle: working, tuning: tuning)
        } catch {
            foldLog("overlay failed: \(error.localizedDescription)")
            gate.fail()
            return
        }
        }
        let showMs = Date().timeIntervalSince(showStart) * 1000
        gate.captured()
        troughAngle = shownAngle
        lastAngle = troughAngle
        risingAt = .distantPast
        gestureStart = Date()
        foldLog(String(format: "overlay on %d display(s): capture %.0f ms, show %.0f ms",
                       shots.count, stagingMs, showMs))
    }

    /// Drives the real gesture path (gate, staging, capture, teardown) with a synthetic close and
    /// open, so blur mode can be tested without touching the lid.
    func demoGesture() {
        foldLog("demo gesture requested")
        if !enabled { start() }
        // The real sensor keeps reporting while the synthetic angles run; two sources make the
        // gate flap idle↔captureRequested and prove nothing.
        LidSensor.shared.onChange = nil
        LidSensor.shared.stop()
        Task { @MainActor in
            let down = stride(from: working, through: working - 88, by: -3).map { $0 }
            let up = stride(from: working - 88, through: working + 2, by: 4).map { $0 }
            for angle in down + up {
                receive(angle)
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            foldLog("demo gesture done")
        }
    }

    /// Captures the desktop and plays one open→closed→open pass, without the sensor.
    func preview(seconds: Double = 6) {
        foldLog("preview requested")
        previewingUntil = Date().addingTimeInterval(seconds + 1)
        Task { @MainActor in
            if Prefs.shared.foldBlurOnly {
                if true {
                    guard !NSScreen.screens.isEmpty else { foldLog("preview found no displays"); return }
                    shownAngle = working
                    blurFold.show(angle: working, working: working, tuning: tuning)
                    let start = Date()
                    while Date().timeIntervalSince(start) < seconds {
                        try? await Task.sleep(nanoseconds: 40_000_000)
                        let t = min(1, Date().timeIntervalSince(start) / (seconds * 0.6))
                        let fade = tuning.validated.fadeAngle
                        blurFold.update(angle: working - (working - fade) * t, working: working, tuning: tuning)
                    }
                    blurFold.hide(fade: 0.2)
                    foldLog("blur preview done")
                    return
                }
            }
            do {
                let shots = try await DesktopCapture.snapshots()
                guard !shots.isEmpty else { foldLog("preview found no displays"); return }
                shownAngle = working
                try overlay.show(snapshots: shots, angle: working, tuning: tuning)
                FoldPreviewModel.shared.captureAllowed = true
                FoldPreviewModel.shared.captureChecked = true
                foldLog("preview overlay on \(shots.count) display(s)")
                let start = Date()
                while Date().timeIntervalSince(start) < seconds {
                    let t = min(1, Date().timeIntervalSince(start) / seconds)
                    let eased = t < 0.5 ? t * 2 : (1 - t) * 2
                    overlay.update(angle: working - (working - 45) * eased, tuning: tuning)
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                overlay.hide()
                foldLog("preview finished")
            } catch {
                FoldPreviewModel.shared.captureAllowed = false
                FoldPreviewModel.shared.captureChecked = true
                foldLog("preview failed: \(error.localizedDescription)")
            }
        }
    }

    private func teardown() {
        revealing = false
        stopFrames()
        staging = false
        idleHide?.cancel(); idleHide = nil
        if showing {
            let ms = Int(Date().timeIntervalSince(gestureStart) * 1000)
            foldLog(String(format: "hidden at %d deg — %d/%d frames over %d ms, %d changes, %d dup, avg Δ %.0f ms",
                           Int(shownAngle), drawCount, frameCount, ms, changeCount, dupReports, reportInterval * 1000))
            frameCount = 0
            drawCount = 0
            changeCount = 0
            dupReports = 0
        }
        blurFold.hide(fade: 0.14)
        overlay.hide(fade: 0.14)
        gate.reset()
        capturing = false
    }
}
