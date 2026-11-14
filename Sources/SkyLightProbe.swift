import AppKit
import Foundation

/// Clean-room probe for the private SkyLight entry points a display-space transform would need.
/// It only resolves symbols — it creates no space and touches no window, so running it cannot
/// disturb the session. Written independently; no code from any unlicensed project.
enum SkyLightProbe {
    private static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private static let symbols = [
        "SLSMainConnectionID",
        "SLSSpaceCreate",
        "SLSSpaceSetAbsoluteLevel",
        "SLSSpaceAddWindowsAndRemoveFromSpaces",
        "SLSShowSpaces",
        "SLSManagedDisplaySetDisplayTransform",
        "CGSSetWindowTransform",
        "CGSGetWindowTransform"
    ]


    /// Contained experiment: transform one window of our own and put it back. Nothing global is
    /// touched, so a wrong argument can only distort a window we own.
    static func windowTransformDemo() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let handle = dlopen(path, RTLD_NOW) else { print("skylight: framework not loadable"); return }
        defer { dlclose(handle) }
        typealias ConnFn = @convention(c) () -> Int32
        typealias SetFn = @convention(c) (Int32, UInt32, CGAffineTransform) -> Int32
        typealias GetFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGAffineTransform>) -> Int32
        guard let connSym = dlsym(handle, "SLSMainConnectionID"),
              let setSym = dlsym(handle, "CGSSetWindowTransform"),
              let getSym = dlsym(handle, "CGSGetWindowTransform") else {
            print("skylight: needed symbols missing")
            return
        }
        let conn = unsafeBitCast(connSym, to: ConnFn.self)()
        let set = unsafeBitCast(setSym, to: SetFn.self)
        let get = unsafeBitCast(getSym, to: GetFn.self)
        print("skylight: connection \(conn)")

        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .systemOrange
        window.level = .floating
        window.orderFrontRegardless()
        let wid = UInt32(window.windowNumber)
        let tilt = CGAffineTransform(a: 1, b: 0.25, c: -0.25, d: 1, tx: 0, ty: 0)
        let setResult = set(conn, wid, tilt)
        var readBack = CGAffineTransform.identity
        let getResult = get(conn, wid, &readBack)
        print(String(format: "skylight: set=%d get=%d b=%.3f c=%.3f", setResult, getResult, readBack.b, readBack.c))
        _ = set(conn, wid, .identity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            window.orderOut(nil)
            print("skylight: window transform restored")
        }
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let handle = dlopen(path, RTLD_NOW) else {
            print("skylight: framework not loadable (\(String(cString: dlerror())))")
            return
        }
        defer { dlclose(handle) }
        var found = 0
        for name in symbols {
            if let symbol = dlsym(handle, name) {
                found += 1
                print("skylight: \(name) -> \(String(format: "%p", Int(bitPattern: symbol)))")
            } else {
                print("skylight: \(name) -> missing")
            }
        }
        print("skylight: \(found)/\(symbols.count) present on this OS")
    }
}
