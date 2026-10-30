import Foundation

#if SC_SHIPPING
// The shipping build carries no self-tests, conformance oracles or snapshot renderers (`./build.sh build --release` leaves them out to keep the app small). The command-line
// switches stay recognised and say where the real ones are, instead of starting the app by accident.
enum Harness {
    static let message = "This build has no self-tests or snapshots. Use ./build.sh selftest / ./build.sh snapshot (the full build), or SC_FULL_RELEASE=1 ./build.sh build --release.\n"

    @MainActor static func runSelfTests(filter: String?) async -> Int32 { FileHandle.standardError.write(Data(message.utf8)); return 2 }
    @MainActor static func runSnapshots(to dir: URL, filter: String?) async -> Int32 { FileHandle.standardError.write(Data(message.utf8)); return 2 }
}
#endif
