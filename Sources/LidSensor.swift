import Foundation
import IOKit.hid

/// Reads the MacBook lid-angle sensor: Apple HID 0x05AC/0x8104, feature report 1,
/// bytes 1–2 little-endian degrees. Ported from kavishshahh/iphone-duo-animation (MIT).
final class LidSensor {
    static let shared = LidSensor()

    private(set) var available = false
    /// Called on the main queue. nil means the sensor is unreadable or disconnected.
    var onChange: ((Double?) -> Void)?

    private let queue = DispatchQueue(label: "com.lov3u.sino.lid", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var device: IOHIDDevice?
    private var failures = 0

    private init() {}

    func start() { queue.async { self.startLocked() } }
    func stop() { queue.async { self.stopLocked() } }

    private func startLocked() {
        stopLocked()
        guard let device = Self.probe() else {
            available = false
            publish(nil)
            return
        }
        available = true
        self.device = device
        publish(Self.read(device))

        let clock = DispatchSource.makeTimerSource(queue: queue)
        // The sensor only changes its report every ~90 ms (measured), so 30 Hz polling is
        // already three samples per change; faster costs power for duplicates.
        clock.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33), leeway: .milliseconds(3))
        clock.setEventHandler { [weak self] in self?.poll() }
        timer = clock
        clock.resume()
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        failures = 0
    }

    private func poll() {
        guard let device else { return }
        guard let angle = Self.read(device) else {
            failures += 1
            if failures >= 5 {
                available = false
                publish(nil)
                stopLocked()
                queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in self?.startLocked() }
            }
            return
        }
        failures = 0
        publish(angle)
    }

    private func publish(_ angle: Double?) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(angle) }
    }

    // MARK: IOKit

    private static func probe() -> IOHIDDevice? {
        let opts = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, opts)
        let matches: NSArray = [[kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, unsafeBitCast(matches, to: CFArray.self))
        // The manager open status is not a reliable gate: on some Macs it reports
        // kIOReturnExclusiveAccess while the device is still enumerable and readable.
        IOHIDManagerOpen(manager, opts)
        let devices = ((IOHIDManagerCopyDevices(manager) as? NSSet)?.allObjects as? [IOHIDDevice]) ?? []
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
        return winner
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
