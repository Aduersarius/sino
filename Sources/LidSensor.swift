import Foundation
import IOKit.hid

/// Reads the MacBook lid-angle sensor: Apple HID 0x05AC/0x8104, feature report 1,
/// bytes 1–2 little-endian degrees. Ported from kavishshahh/iphone-duo-animation (MIT).
final class LidSensor {
    static let shared = LidSensor()

    private(set) var available = false
    /// Called on the main queue. nil means the sensor is unreadable or disconnected.
    var onChange: ((Double?) -> Void)?
    /// Secondary listener for Settings preview, so opening/closing Settings never stops LidFold.
    var onPreview: ((Double?) -> Void)?

    private let queue = DispatchQueue(label: "com.lov3u.sino.lid", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var device: IOHIDDevice?
    private var failures = 0
    private var running = false
    private var everFound = false
    private var sentSilent = false
    private var retryWork: DispatchWorkItem?

    private init() {}

    func start() {
        queue.async {
            self.running = true
            if self.timer != nil {
                if let device = self.device, let angle = Self.read(device) {
                    self.publish(angle)
                }
                return
            }
            self.startLocked()
        }
    }

    func stop() {
        guard onChange == nil && onPreview == nil else { return }
        queue.async {
            self.running = false
            self.sentSilent = false
            self.stopLocked()
        }
    }

    /// Re-probes immediately after display wake when the sensor went silent while shut.
    func kick() {
        queue.async {
            guard self.running, self.timer == nil else { return }
            self.startLocked()
        }
    }

    private func startLocked() {
        stopLocked()
        guard running else { return }
        guard let (device, initialAngle) = Self.probe() else {
            available = false
            if !sentSilent {
                sentSilent = true
                publish(nil)
            }
            if everFound || Self.devicePresent() {
                scheduleRetryLocked(after: 1.0)
            }
            return
        }
        sentSilent = false
        everFound = true
        available = true
        self.device = device
        publish(initialAngle)

        let clock = DispatchSource.makeTimerSource(queue: queue)
        // The sensor only changes its report every ~90 ms (measured), so 30 Hz polling is
        // already three samples per change; faster costs power for duplicates.
        clock.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33), leeway: .milliseconds(3))
        clock.setEventHandler { [weak self] in self?.poll() }
        timer = clock
        clock.resume()
    }

    private func stopLocked() {
        retryWork?.cancel()
        retryWork = nil
        timer?.cancel()
        timer = nil
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        failures = 0
    }

    private func scheduleRetryLocked(after delay: TimeInterval) {
        retryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.startLocked()
        }
        retryWork = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func poll() {
        guard let device else { return }
        guard let angle = Self.read(device) else {
            failures += 1
            if failures >= 5 {
                available = false
                if !sentSilent {
                    sentSilent = true
                    publish(nil)
                }
                stopLocked()
                if running { scheduleRetryLocked(after: 0.8) }
            }
            return
        }
        failures = 0
        sentSilent = false
        publish(angle)
    }

    private func publish(_ angle: Double?) {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(angle)
            self?.onPreview?(angle)
        }
    }

    // MARK: IOKit

    private static func devicePresent() -> Bool {
        let opts = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, opts)
        let matches: NSArray = [[kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, unsafeBitCast(matches, to: CFArray.self))
        IOHIDManagerOpen(manager, opts)
        let count = (IOHIDManagerCopyDevices(manager) as NSSet?)?.count ?? 0
        IOHIDManagerClose(manager, opts)
        return count > 0
    }

    private static func probe() -> (IOHIDDevice, Double)? {
        let opts = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, opts)
        let matches: NSArray = [[kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, unsafeBitCast(matches, to: CFArray.self))
        // The manager open status is not a reliable gate: on some Macs it reports
        // kIOReturnExclusiveAccess while the device is still enumerable and readable.
        IOHIDManagerOpen(manager, opts)
        let devices = ((IOHIDManagerCopyDevices(manager) as NSSet?)?.allObjects as? [IOHIDDevice]) ?? []
        var winner: IOHIDDevice?
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, opts) == kIOReturnSuccess else { continue }
            let ok = read(candidate) != nil
            IOHIDDeviceClose(candidate, opts)
            if ok { winner = candidate; break }
        }
        // Closing the manager invalidates devices it enumerated, so the winner is re-opened
        // afterwards for polling rather than held across the close.
        IOHIDManagerClose(manager, opts)
        guard let winner, IOHIDDeviceOpen(winner, opts) == kIOReturnSuccess else { return nil }
        guard let angle = read(winner) else {
            IOHIDDeviceClose(winner, opts)
            return nil
        }
        return (winner, angle)
    }

    private static func read(_ device: IOHIDDevice) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = CFIndex(bytes.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &count)
        guard result == kIOReturnSuccess, count >= 3 else { return nil }
        let degrees = Double(UInt16(bytes[2]) << 8 | UInt16(bytes[1]))
        return (0...200).contains(degrees) ? degrees : nil
    }
}
