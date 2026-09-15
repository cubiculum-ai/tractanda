import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension SetupEngine {
    var tuiCommand: URL { roots.commands.appendingPathComponent("tractanda-tui") }
    var tuiCommandTarget: String { clientLink.appendingPathComponent("bin/tractanda-tui").path }

    func ownsTUICommand() -> Bool {
        var metadata = stat()
        guard lstat(tuiCommand.path, &metadata) == 0,
            !trustedOwnership || metadata.st_uid == 0,
            isLink(tuiCommand)
        else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: tuiCommand.path))
            == tuiCommandTarget
    }

    func publishTUICommand() throws {
        if exists(tuiCommand) {
            if !ownsTUICommand() {
                FileHandle.standardError.write(
                    Data("Kept the existing \(tuiCommand.path); use \(tuiCommandTarget).\n".utf8))
            }
            return
        }
        if !exists(roots.commands) { try ensureRootDirectory(roots.commands) }
        if trustedOwnership {
            // /usr/local/bin may be root:wheel 0775. Only root's group may have write access.
            var current = roots.commands
            while current.path != "/" {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                guard !isLink(current), attributes[.type] as? FileAttributeType == .typeDirectory,
                    (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                    mode & 0o002 == 0,
                    mode & 0o020 == 0 || (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == 0
                else {
                    FileHandle.standardError.write(
                        Data("Command directory is not protected; use \(tuiCommandTarget).\n".utf8))
                    return
                }
                current.deleteLastPathComponent()
            }
        }
        // Creation fails if a competing command appeared; never replace it.
        try FileManager.default.createSymbolicLink(
            atPath: tuiCommand.path, withDestinationPath: tuiCommandTarget)
    }

    func removeTUICommandIfUnused() throws {
        if !exists(clientLink), ownsTUICommand() { try FileManager.default.removeItem(at: tuiCommand) }
    }
}
