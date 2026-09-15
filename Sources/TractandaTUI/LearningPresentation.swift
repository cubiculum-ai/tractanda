import Foundation
import TractandaCore

struct LearningSettingsDraft {
    let categoryID: String
    let revisionID: String
    let original: CategoryLearningSettings
    var fields: [TextBuffer] {
        [
            TextBuffer(original.mode.rawValue), TextBuffer(String(original.threshold)),
            TextBuffer(original.usesRuleMatches ? "yes" : "no"),
            TextBuffer(String(original.minimumExamplesPerLabel)),
            TextBuffer(String(original.maximumExamplesPerLabel)),
        ]
    }
    static let labels = [
        "Mode (off / suggestions)", "Score threshold (-2 to 2)",
        "Use rule matches as positives (yes / no)", "Minimum examples per label (1–400)",
        "Maximum examples per label (minimum–400)",
    ]

    func edit(_ fields: [TextBuffer]) throws -> LearningEdit? {
        guard fields.count == Self.labels.count,
            let mode = CategoryLearningSettings.Mode(rawValue: fields[0].text.lowercased()),
            let threshold = Double(fields[1].text),
            ["yes", "no", "true", "false"].contains(fields[2].text.lowercased()),
            let minimum = Int(fields[3].text), let maximum = Int(fields[4].text)
        else {
            throw TractandaError(
                "invalidLearningSettings", "Enter a valid mode, threshold, yes/no and integer limits.")
        }
        var settings = original  // Keep the category's existing LSM recipe and dimension choices.
        settings.mode = mode
        settings.threshold = threshold
        settings.usesRuleMatches = ["yes", "true"].contains(fields[2].text.lowercased())
        settings.minimumExamplesPerLabel = minimum
        settings.maximumExamplesPerLabel = maximum
        try settings.validate()
        guard settings != original else { return nil }
        return .settings(
            .init(
                categoryID: categoryID, expectedRevisionID: revisionID, operationID: Identifier.make(),
                settings: settings.itemValue))
    }
}

enum LearningPresentation {
    /// Returns the content between the common title and status/function-key footer.
    static func lines(_ workspace: LearningWorkspace, width: Int, height: Int) -> [ScreenLine] {
        let mode = workspace.mode == .suggestions ? "Suggestions" : "Teach from items"
        let range =
            workspace.rows.isEmpty
            ? "0 of \(workspace.total)"
            : "\(workspace.position + 1)–\(workspace.position + workspace.rows.count) of \(workspace.total)"
        var lines = [
            ScreenLine(text: " Learning · \(workspace.title)", style: .title),
            ScreenLine.controls(
                [
                    ("[ Previous", .previousResults), ("] Next", .nextResults),
                    ("F filter", .filter),
                ], prefix: mode + " · " + range),
        ]
        if let state = workspace.state {
            lines.append(
                ScreenLine(
                    text:
                        " \(state.status.rawValue) · \(state.positiveExamples) positive · \(state.negativeExamples) negative · \(state.unknownItems) unknown"
                ))
            if height >= 18 && (state.emptyExamples > 0 || state.omittedExamples > 0) {
                lines.append(
                    ScreenLine(
                        text:
                            " \(state.emptyExamples) empty examples skipped · \(state.omittedExamples) beyond training limit"
                    ))
            }
        }
        lines += TerminalText.lines(workspace.explanation, columns: width - 2)
            .prefix(height >= 18 ? 2 : 1).map { ScreenLine(text: " " + $0) }
        lines.append(
            .controls([
                ("T Train", .trainLearning), ("E Teach", .learningExamples),
                ("S Suggestions", .learningSuggestions), ("O Settings", .learningSettings),
                ("U Reset", .resetLearning),
            ]))
        lines.append(
            ScreenLine(
                text: workspace.mode == .suggestions ? "   Score    Subject" : "   Stored   Subject",
                style: .header))
        let previewSize = height >= 18 ? 3 : 0
        let capacity = max(1, height - 3 - lines.count - previewSize)
        let start = TerminalViewport.start(
            selected: workspace.index, count: workspace.rows.count, capacity: capacity,
            previous: workspace.firstVisibleIndex)
        workspace.firstVisibleIndex = start
        for index in start..<min(workspace.rows.count, start + capacity) {
            let row = workspace.rows[index]
            let label: String
            if let suggestion = row.suggestion {
                label = String(format: "%.3f", suggestion.score)
            } else {
                label =
                    row.item.fields["categoryOverrides"]?.map?[workspace.categoryID]?.string
                    ?? row.item.fields["learningFeedback"]?.map?[workspace.categoryID]?.map?["action"]?.string
                    ?? "—"
            }
            lines.append(
                ScreenLine(
                    text: " \(workspace.index == index ? ">" : " ") " + TerminalText.fit(label, columns: 8)
                        + " " + (row.item.fields["subject"]?.string ?? "Untitled item"),
                    style: index == workspace.index ? .activeSelection : .normal,
                    hits: [
                        MouseHit(
                            columns: 0..<width,
                            target: .learningRow(index, row.item.itemID + ":" + row.item.revisionID))
                    ]))
        }
        if workspace.rows.isEmpty {
            lines.append(
                ScreenLine(
                    text: workspace.mode == .suggestions
                        ? " No suggestions to review. E opens teaching items."
                        : " No teaching items match this filter."))
        }
        if previewSize > 0 {
            while lines.count < height - 3 - previewSize { lines.append(ScreenLine(text: "")) }
            lines.append(
                .controls(
                    [
                        ("Enter reads", .activate), ("A assign", .acceptLearning),
                        ("N reject", .rejectLearning), ("D dismiss", .dismissLearning),
                        ("X exclude", .excludeLearning),
                    ], prefix: "Preview", style: .header))
            lines += TerminalText.lines(
                String((workspace.current?.item.fields["body"]?.string ?? "").prefix(4096)),
                columns: width - 2
            )
            .prefix(2).map { ScreenLine(text: " " + $0) }
        }
        return Array(lines.prefix(height - 3))
    }
}
