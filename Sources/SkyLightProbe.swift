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

    static func run() {
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
