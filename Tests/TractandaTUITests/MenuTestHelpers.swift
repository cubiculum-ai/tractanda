import XCTest

@testable import TractandaTUI

/// Select the actual enabled command hit target, independently of menu row ordering.
func selectApplicationMenuCommand(_ command: TUICommand, in app: TerminalApplication) {
    app.handle(.function(10))
    app.handle(.left)  // File -> Tractanda.
    let frame = app.render(columns: 132, rows: 35)
    for (row, line) in frame.enumerated() {
        if let hit = line.hits.last(where: { $0.target == .menuCommand(command) }), !hit.columns.isEmpty {
            let column = hit.columns.lowerBound
            app.handleMouse(
                .init(kind: .press, button: .left, column: column, row: row, modifiers: []), at: 1)
            app.handleMouse(
                .init(kind: .release, button: .left, column: column, row: row, modifiers: []), at: 1.01)
            return
        }
    }
    XCTFail("Missing enabled application menu command: \(command)")
}
