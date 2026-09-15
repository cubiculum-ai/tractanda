import CTractandaPlatform
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class StartupSignalTests: XCTestCase {
    func testStopBeforeGuardCannotBecomeReady() {
        let installed = tractanda_start_signals()
        XCTAssertEqual(installed, 0)
        guard installed == 0 else { return }
        defer {
            tractanda_startup_shutdown_guard_end()
            tractanda_restore_signals()
        }
        XCTAssertEqual(raise(SIGTERM), 0)
        tractanda_startup_shutdown_guard_begin()
        XCTAssertEqual(tractanda_stopping(), 1)
        XCTAssertEqual(tractanda_startup_shutdown_guard_ready(), 0)
    }

    func testReadyDaemonRetainsCoordinatedShutdown() {
        let installed = tractanda_start_signals()
        XCTAssertEqual(installed, 0)
        guard installed == 0 else { return }
        defer {
            tractanda_startup_shutdown_guard_end()
            tractanda_restore_signals()
        }
        tractanda_startup_shutdown_guard_begin()
        XCTAssertEqual(tractanda_startup_shutdown_guard_ready(), 1)
        XCTAssertEqual(raise(SIGTERM), 0)
        XCTAssertEqual(tractanda_stopping(), 1)
        XCTAssertEqual(tractanda_terminate_if_stopping(), 0)
    }
}
