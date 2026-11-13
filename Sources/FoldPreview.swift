import Foundation
import AppKit
import SwiftUI

/// Geometry-only preview of the iPhone Duo lid fold: the same inverse projection as
/// Fold.metal, evaluated on the CPU. No capture, no Metal, no frost or glow.
final class FoldPreviewModel: ObservableObject {
    static let shared = FoldPreviewModel()
    @Published var angle: Double = 112
    @Published var followLid = false
    @Published var sensorAngle: Double?
    @Published var sensorAvailable = false
    @Published var captureAllowed = false
    @Published var captureChecked = false

    private init() {}

    var shown: Double { followLid ? (sensorAngle ?? angle) : angle }

    var tuning: FoldTuning {
        var t = FoldTuning()
        t.workingAngle = Prefs.shared.foldAngle
        t.frost = Prefs.shared.foldBlur
        return t
    }

    /// Reads both states once, without prompting: preflight for capture, a short sensor run
    /// for the angle. Neither claims "unavailable" before it has actually looked.
    func refresh() {
        // Deliberately no capture preflight here: on this macOS a preflight from the app is
        // what raises the Screen Recording disclosure, so it is checked only on an explicit tap.
        if sensorAvailable { return }
        let sensor = LidSensor.shared
        sensor.onChange = { [weak self] reading in
            guard let self else { return }
            self.sensorAvailable = sensor.available
            if let reading { self.sensorAngle = reading }
        }
        sensor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.followLid else { return }
            self.sensorAvailable = sensor.available
            sensor.onChange = nil
            sensor.stop()
        }
    }

    func syncSensor() {
        let sensor = LidSensor.shared
        guard followLid else {
            sensor.onChange = nil
            sensor.stop()
            return
        }
        sensor.onChange = { [weak self] reading in
            guard let self else { return }
            self.sensorAvailable = sensor.available
            self.sensorAngle = reading
        }
        sensor.start()
    }

    func shutdown() {
        followLid = false
        LidSensor.shared.onChange = nil
        LidSensor.shared.stop()
    }
}

struct FoldPreviewCard: View {
    @ObservedObject var model = FoldPreviewModel.shared
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: FoldRender.image(angle: model.shown, tuning: model.tuning))
                .resizable()
                .interpolation(.high)
                .frame(width: 236, height: 147)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Slider(value: $model.angle, in: 8...135)
                    .frame(width: 140)
                    .disabled(model.followLid)
                Text("\(Int(model.shown))°")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow lid", isOn: $model.followLid)
                    .toggleStyle(.switch)
                    .disabled(!model.sensorAvailable)
            }

            HStack(spacing: 8) {
                Text("Starts folding at").font(.system(size: 11))
                Slider(value: Binding(get: { prefs.foldAngle },
                                      set: { prefs.setFoldAngle($0) }),
                       in: 75...135, step: 1)
                    .frame(width: 130)
                Text("\(Int(prefs.foldAngle))°")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Blur").font(.system(size: 11))
                Slider(value: Binding(get: { prefs.foldBlur },
                                      set: { prefs.setFoldBlur($0) }),
                       in: 0...1, step: 0.05)
                    .frame(width: 130)
                Text(String(format: "%.2f", prefs.foldBlur))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Ignore lid jitter").font(.system(size: 11))
                Slider(value: Binding(get: { prefs.foldJitter },
                                      set: { prefs.setFoldJitter($0) }),
                       in: 0...5, step: 0.5)
                    .frame(width: 130)
                Text(String(format: "%.1f°", prefs.foldJitter))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let live = model.sensorAngle, prefs.foldAngle > live - 5 {
                Text("Lid reads \(Int(live))° — with this setting the fold starts immediately")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Text(model.sensorAvailable
                 ? (model.sensorAngle == nil ? "Lid sensor found, waiting for a reading" : "Live lid angle")
                 : "No lid-angle sensor on this Mac \u{2014} slider only")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(!model.captureChecked
                     ? "Screen Recording not checked yet"
                     : (model.captureAllowed
                        ? "Screen Recording granted \u{2014} the fold can play on the desktop"
                        : "Screen Recording needed before the fold can cover the desktop"))
                    .font(.system(size: 10))
                    .foregroundStyle(model.captureChecked && !model.captureAllowed
                                     ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                if model.captureAllowed {
                    Button("Preview") { LidFold.shared.preview() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                if !model.captureAllowed {
                    Button(model.captureChecked ? "Open Settings" : "Allow…") {
                        DesktopCapture.requestAccess()
                        model.captureChecked = true
                        model.captureAllowed = DesktopCapture.allowed
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
        }
        .onAppear { model.refresh(); model.syncSensor() }
        .onDisappear { model.shutdown() }
        .onChange(of: model.followLid) { _, _ in model.syncSensor() }
    }
}
