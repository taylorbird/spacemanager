import Foundation

// The single quarantined private-API surface: SLSCopyManagedDisplaySpaces
// (plus its connection-ID getter), loaded via dlopen/dlsym so the binary has
// no link-time private-framework dependency. Verified on macOS 26.6 (25G72).
enum SkyLight {
    typealias MainConnectionIDFn = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    static let mainConnectionID: MainConnectionIDFn? = handle.flatMap { h in
        dlsym(h, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionIDFn.self) }
    }

    static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = handle.flatMap { h in
        dlsym(h, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) }
    }

    static var available: Bool {
        mainConnectionID != nil && copyManagedDisplaySpaces != nil
    }
}
