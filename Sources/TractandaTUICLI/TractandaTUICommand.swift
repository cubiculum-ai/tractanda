import Foundation
import TractandaCore
import TractandaTUI

@main
enum TractandaTUICommand {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print(
                    "Usage: tractanda-tui [SOCKET | --profile NAME | --socket PATH] [--no-start] [--items] [--view ITEM_ID] [--recovery-file PATH] [--appearance-file PATH] [--function-keys auto|10|12] [--mouse on|off]\nWithout a connection argument, the default opens Views above the selected report. --items opens the familiar full-height item browser; --view selects a saved view. They may be combined."
                )
                return
            }
            var viewID: String?
            var itemsOnly = false
            var recoveryURL: URL?
            var appearanceURL: URL?
            var functionKeys = FunctionKeyDisplay.automatic
            var mouseEnabled = true
            var connection = ConnectionOptions()
            while !arguments.isEmpty {
                try connection.consume(&arguments)
                guard let flag = arguments.first else { break }
                arguments.removeFirst()
                switch flag {
                case "--mouse":
                    guard let value = arguments.first, ["on", "off"].contains(value) else {
                        throw CommandError.usage
                    }
                    arguments.removeFirst()
                    mouseEnabled = value == "on"
                case "--function-keys":
                    guard let value = arguments.first, let display = FunctionKeyDisplay(rawValue: value)
                    else {
                        throw CommandError.usage
                    }
                    arguments.removeFirst()
                    functionKeys = display
                case "--view", "--recovery-file", "--appearance-file":
                    guard let value = arguments.first else { throw CommandError.usage }
                    arguments.removeFirst()
                    if flag == "--view" {
                        viewID = value
                    } else if flag == "--appearance-file" {
                        appearanceURL = URL(fileURLWithPath: value)
                    } else {
                        recoveryURL = URL(fileURLWithPath: value)
                    }
                case "--items":
                    itemsOnly = true
                default:
                    guard !flag.hasPrefix("-"), connection.socketPath == nil else { throw CommandError.usage }
                    connection.socketPath = flag
                }
            }
            try TerminalApplication(
                connection: connection.resolve(), recoveryURL: recoveryURL, viewID: viewID,
                itemsOnly: itemsOnly,
                appearanceURL: appearanceURL, functionKeys: functionKeys, mouseEnabled: mouseEnabled
            ).run()
        } catch {
            FileHandle.standardError.write(Data("tractanda-tui: \(error)\n".utf8))
            exit(1)
        }
    }
    private enum CommandError: Error { case usage }
}
