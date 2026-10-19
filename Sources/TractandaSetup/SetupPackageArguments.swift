import Foundation

struct SetupPackageArguments: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case prermUpgrade = "prerm-upgrade"
        case preinst
        case configure
        case abortUpgrade = "abort-upgrade"
        case remove
        case runtimeGuard = "runtime-guard"
    }

    let action: Action
    let descriptor: URL?
    let instance: String?

    static func parse(_ arguments: [String]) throws -> Self? {
        guard let command = arguments.first else { return nil }

        if command == "--package-runtime-guard" {
            guard arguments.count == 2, validInstance(arguments[1]) else {
                throw SetupError("Use --package-runtime-guard INSTANCE with a valid instance name.")
            }
            return Self(action: .runtimeGuard, descriptor: nil, instance: arguments[1])
        }

        guard command == "--package-lifecycle" else { return nil }
        guard arguments.count >= 2, let action = Action(rawValue: arguments[1]), action != .runtimeGuard
        else {
            throw SetupError("Unknown or invalid package lifecycle action.")
        }

        switch action {
        case .preinst, .configure:
            guard arguments.count == 4, arguments[2] == "--descriptor",
                let descriptor = normalizedDescriptorURL(arguments[3])
            else {
                throw SetupError("Use --package-lifecycle \(action.rawValue) --descriptor ABSOLUTE_PATH.")
            }
            return Self(action: action, descriptor: descriptor, instance: nil)
        case .prermUpgrade, .abortUpgrade, .remove:
            guard arguments.count == 2 else {
                throw SetupError("Package lifecycle action has unexpected arguments.")
            }
            return Self(action: action, descriptor: nil, instance: nil)
        case .runtimeGuard:
            throw SetupError("Runtime guard is not a package lifecycle action.")
        }
    }

    private static func normalizedDescriptorURL(_ path: String) -> URL? {
        guard path.utf8.count <= 4_096, path.hasPrefix("/"), path != "/",
            !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
            URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path == path
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func validInstance(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count),
            bytes.first != 0x2d, bytes.last != 0x2d
        else { return false }
        return bytes.allSatisfy {
            (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                || (0x30...0x39).contains($0) || $0 == 0x2d
        }
    }
}
