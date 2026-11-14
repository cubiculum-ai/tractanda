import Foundation
import XCTest

final class MemoryWorkflowCommandTests: XCTestCase {
    func testMalformedMemoryCommandsFailBeforeServerConnection() throws {
        for arguments in [["memory", "recall"], ["memory", "remember"], ["memory", "resume"]] {
            let process = Process()
            process.executableURL = try currentBuiltTestCLI(anchor: Self.self)
            process.arguments = arguments
            let output = Pipe()
            process.standardError = output
            process.standardOutput = Pipe()
            try process.run()
            let error = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
            XCTAssertTrue(String(decoding: error, as: UTF8.self).contains("usage"))
        }
    }
}
