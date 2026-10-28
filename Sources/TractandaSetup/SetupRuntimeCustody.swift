import CTractandaPlatform
import CTractandaSetupMetadata
import Foundation

extension SetupEngine {
    var usesAnchoredMacRuntime: Bool {
        trustedOwnership && roots.platform == .macos && roots.runtime.path == "/private/var/run/tractanda"
    }
    func withAnchoredMacRuntime<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        guard usesAnchoredMacRuntime, rootCheck(),
            let context = tractanda_setup_runtime_open("/private/var/run", 0, 1)
        else {
            throw SetupError("Cannot establish protected macOS runtime custody.")
        }
        defer { tractanda_setup_runtime_close(context) }
        let result = try body(context)
        guard tractanda_setup_runtime_validate(context) == 0 else {
            throw SetupError("macOS runtime parent changed during the operation.")
        }
        return result
    }
    func prepareAnchoredMacRuntime(instance: String, uid: UInt32) throws {
        guard uid != 0, SetupPackageState.validInstance(instance) else {
            throw SetupError("Managed runtime requires an unprivileged service and exact instance.")
        }
        try withAnchoredMacRuntime { context in
            guard tractanda_setup_runtime_prepare(context, instance, uid) == 0 else {
                throw SetupError("Cannot prepare runtime without protected descriptor custody.")
            }
        }
    }
}
