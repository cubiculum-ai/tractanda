import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaTUI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class LearningWorkflowTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 50011
        let bob: UInt32 = 50012
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case getuid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [70001])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": try user(forUID: getuid())
            case "alice": try user(forUID: alice)
            case "bob": try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 70001
        }
    }
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let service: ItemService
        let category: Revision
        var client: ItemClient {
            ItemClient(transport: { self.service.handle($0, peerUID: self.store.ownerUID) })
        }
        init(seed: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trac-tui-learning-" + Identifier.make())
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
            var settings = CategoryLearningSettings()
            settings.configuration.dimensions = 3
            category = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Club café 文"),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                        ]),
                        "foreign.category": .text("keep"), "learningSettings": settings.itemValue,
                    ], operationID: Identifier.make())
            ).revision
            if seed {
                for text in ["chess tournament players", "chess players board"] {
                    _ = try item(text, label: "include")
                }
                for text in ["garden vegetables soil", "garden soil flowers"] {
                    _ = try item(text, label: "exclude")
                }
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ text: String, label: String? = nil) throws -> Revision {
            var fields: [String: ItemValue] = [
                "subject": .text(text), "body": .text("café 文 👩🏽‍💻"), "foreign.metadata": .integer(42),
            ]
            if let label { fields["categoryOverrides"] = .object([category.itemID: .text(label)]) }
            return try store.commit(
                CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
            ).revision
        }
        func revise(_ item: Revision, _ fields: [String: ItemValue]) throws -> Revision {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: fields, operationID: Identifier.make())
            ).revision
        }
        func journal() -> RecoveryJournal {
            RecoveryJournal(url: root.appendingPathComponent("pending.json"), socket: "/fixture")
        }
        func app(client: ItemClient? = nil, journal: RecoveryJournal? = nil) throws -> TerminalApplication {
            try TerminalApplication(
                client: client ?? self.client, journal: journal ?? self.journal(), itemsOnly: true)
        }
    }

    private func screen(_ app: TerminalApplication, width: Int = 132, height: Int = 30) -> String {
        app.render(columns: width, rows: height).map(\.text).joined(separator: "\n")
    }
    private func open(_ app: TerminalApplication) {
        app.handle(.modified(.text("l"), .option))
        app.handle(.enter)
    }
    private func filter(_ app: TerminalApplication, subject: String) {
        app.handle(.text("f"))
        app.handle(.control(21))
        app.handle(.paste("subject == \"\(subject)\""))
        app.handle(.control(19))
    }

    func testReviewAcceptsOneGuardedEditAndSurvivesResizingAndMenus() throws {
        let f = try Fixture()
        let item = try f.item("chess tournament board")
        let app = try f.app()
        open(app)
        XCTAssertTrue(screen(app).contains("untrained"))
        app.handle(.text("t"))
        XCTAssertTrue(screen(app).contains("ready"))
        for (width, height) in [(48, 12), (80, 25), (132, 40), (30, 8)] {
            let result = app.render(columns: width, rows: height)
            XCTAssertEqual(result.count, height)
            if width < 48 {
                app.handle(.text("a"))
            } else {
                XCTAssertTrue(result.contains { $0.text.contains("chess tournament board") })
            }
        }
        _ = screen(app)
        XCTAssertEqual(try f.store.get(item.itemID), item)
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.escape)
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("Item / immutable revision"))
        app.handle(.escape)
        app.handle(.text("a"))
        let accepted = try f.store.get(item.itemID)
        XCTAssertEqual(accepted.fields["categoryOverrides"]?.map?[f.category.itemID], .text("include"))
        XCTAssertEqual(
            accepted.fields["learningFeedback"]?.map?[f.category.itemID]?.map?["action"], .text("accept"))
        XCTAssertEqual(accepted.fields["foreign.metadata"], .integer(42))
        XCTAssertEqual(try f.store.history(item.itemID).count, 2)
        XCTAssertTrue(screen(app).contains("Accepted:"))
        XCTAssertTrue(screen(app).contains("staleModel"))
    }

    func testTeachFeedbackDistinguishesDismissalNegativeAndManualOverrides() throws {
        let f = try Fixture()
        let item = try f.item("chess tournament board")
        let app = try f.app()
        open(app)
        app.handle(.text("t"))
        app.handle(.text("d"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).negativeExamples, 2)
        XCTAssertNil(try f.store.get(item.itemID).fields["categoryOverrides"])
        app.handle(.text("e"))
        filter(app, subject: "chess tournament board")
        app.handle(.text("n"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).negativeExamples, 3)
        app.handle(.text("c"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).negativeExamples, 2)
        app.handle(.text("a"))
        app.handle(.text("n"))
        app.handle(.text("c"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).positiveExamples, 3)
        XCTAssertEqual(
            try f.store.get(item.itemID).fields["categoryOverrides"]?.map?[f.category.itemID],
            .text("include"))
        app.handle(.text("x"))
        app.handle(.text("c"))
        XCTAssertEqual(
            try f.store.get(item.itemID).fields["categoryOverrides"]?.map?[f.category.itemID],
            .text("exclude"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).negativeExamples, 3)
        XCTAssertTrue(screen(app).contains("manual assignments and exclusions kept"))
    }

    func testTrainingAndResetPreserveCanonicalItemsAndCanBeCanceled() throws {
        let f = try Fixture()
        _ = try f.item("chess tournament board")
        let app = try f.app()
        open(app)
        let before = f.store.state
        app.handle(.text("t"))
        let model = try f.service.learning.status(for: f.category.itemID).modelID
        XCTAssertNotNil(model)
        app.handle(.text("u"))
        app.handle(.escape)
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).modelID, model)
        app.handle(.text("u"))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("Type reset"))
        app.handle(.paste("reset"))
        app.handle(.control(19))
        XCTAssertNil(try f.service.learning.status(for: f.category.itemID).modelID)
        XCTAssertEqual(f.store.state, before)
        app.handle(.text("t"))
        XCTAssertNotEqual(try f.service.learning.status(for: f.category.itemID).modelID, model)
        XCTAssertEqual(f.store.state, before)
    }

    func testInsufficientEvidenceCanBeTaughtFromItemsWithoutImplicitTraining() throws {
        let f = try Fixture(seed: false)
        _ = try f.item("chess board", label: "include")
        _ = try f.item("garden soil", label: "exclude")
        let positive = try f.item("chess players tournament")
        let negative = try f.item("garden vegetables flowers")
        let app = try f.app()
        open(app)
        XCTAssertTrue(screen(app).contains("insufficientEvidence"))
        app.handle(.text("e"))
        filter(app, subject: positive.fields["subject"]!.string!)
        app.handle(.text("a"))
        filter(app, subject: negative.fields["subject"]!.string!)
        app.handle(.text("x"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).status, .untrained)
        app.handle(.text("t"))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).status, .ready)
    }

    func testSettingsValidateWholeEditPreserveRecipeAndRejectConcurrentChanges() throws {
        let f = try Fixture()
        let app = try f.app()
        open(app)
        app.handle(.text("o"))
        app.handle(.control(19))
        XCTAssertEqual(try f.store.get(f.category.itemID), f.category)
        app.handle(.text("o"))
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.text("NaN"))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("invalidLearningSettings"))
        XCTAssertEqual(try f.store.get(f.category.itemID), f.category)
        app.handle(.control(21))
        app.handle(.text("0.25"))
        for (width, height) in [(48, 12), (80, 25), (132, 40)] {
            _ = screen(app, width: width, height: height)
        }
        app.handle(.control(19))
        let saved = try f.store.get(f.category.itemID)
        let settings = try CategoryLearningSettings(saved.fields["learningSettings"])
        XCTAssertEqual(settings.threshold, 0.25)
        XCTAssertEqual(settings.configuration.dimensions, 3)
        XCTAssertEqual(saved.fields["foreign.category"], .text("keep"))
        XCTAssertEqual(try f.store.history(f.category.itemID).count, 2)
        app.handle(.text("o"))
        app.handle(.control(21))
        app.handle(.text("off"))
        let external = try f.revise(saved, ["subject": .text("Renamed elsewhere")])
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("revisionConflict"))
        XCTAssertTrue(screen(app).contains("off"))
        XCTAssertEqual(try f.store.get(f.category.itemID), external)
        app.handle(.escape)
        app.handle(.text("r"))
        app.handle(.text("o"))
        app.handle(.control(21))
        app.handle(.text("off"))
        app.handle(.control(19))
        XCTAssertEqual(try f.service.learning.status(for: f.category.itemID).status, .off)
    }

    func testStaleSuggestionCannotBecomeNewFeedbackAndRefreshAllowsReview() throws {
        let f = try Fixture()
        let item = try f.item("chess tournament board")
        let app = try f.app()
        open(app)
        app.handle(.text("t"))
        let external = try f.revise(item, ["body": .text("Changed by another editor")])
        app.handle(.text("a"))
        XCTAssertEqual(try f.store.get(item.itemID), external)
        XCTAssertTrue(screen(app).contains("stateChanged"))
        XCTAssertFalse(screen(app).contains("chess tournament board"))
        app.handle(.text("r"))
        app.handle(.text("a"))
        XCTAssertEqual(try f.store.history(item.itemID).count, 3)
    }

    func testBoundedPagesRejectChangedModelsAndRetainFilterAndSelectionOnResize() throws {
        let f = try Fixture()
        for index in 0..<40 { _ = try f.item("chess tournament board \(index)") }
        let page = LearningWorkspace(client: f.client, categoryID: f.category.itemID)
        try page.refresh()
        try page.train()
        XCTAssertEqual(page.rows.count, 32)
        XCTAssertEqual(page.total, 40)
        try page.loadPage(forward: true)
        XCTAssertEqual(page.rows.count, 8)
        XCTAssertEqual(page.position, 32)
        _ = try f.service.learning.reset(categoryID: f.category.itemID)
        XCTAssertThrowsError(try page.loadPage(forward: false))
        XCTAssertTrue(page.rows.isEmpty)
        try page.refresh(mode: .examples, expression: "subject == \"*chess*\"")
        XCTAssertEqual(page.total, 42)
        try page.loadPage(forward: true)
        XCTAssertEqual(page.rows.count, 10)
    }

    func testItemChangedBetweenSuggestionAndGetNeverAppearsInReview() throws {
        let f = try Fixture()
        let item = try f.item("chess tournament board")
        _ = try f.service.learning.train(categoryID: f.category.itemID)
        var changed = false
        let client = ItemClient(transport: { data in
            let response = f.service.handle(data, peerUID: f.store.ownerUID)
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if (request["methodCalls"] as! [[Any]])[0][0] as? String == "TractandaLearning/suggest", !changed
            {
                changed = true
                _ = try f.revise(item, ["subject": .text("Changed during hydration")])
            }
            return response
        })
        let page = LearningWorkspace(client: client, categoryID: f.category.itemID)
        XCTAssertThrowsError(try page.refresh())
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertNil(page.category)
    }

    func testLearningFeedbackAndSettingsReplayAfterRestartWithoutAnotherRevision() throws {
        for method in ["TractandaLearning/feedback", "TractandaLearning/settings"] {
            let f = try Fixture()
            let item = try f.item("chess tournament board")
            var dropped = false
            var sent: [Data] = []
            let client = ItemClient(transport: { data in
                let response = f.service.handle(data, peerUID: f.store.ownerUID)
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                if (request["methodCalls"] as! [[Any]])[0][0] as? String == method {
                    sent.append(data)
                    if !dropped {
                        dropped = true
                        throw TractandaError("transportError", "Lost committed response")
                    }
                }
                return response
            })
            let journal = f.journal()
            var app: TerminalApplication? = try f.app(client: client, journal: journal)
            open(app!)
            app!.handle(.text("t"))
            if method.hasSuffix("feedback") {
                app!.handle(.text("a"))
            } else {
                app!.handle(.text("o"))
                app!.handle(.control(21))
                app!.handle(.text("off"))
                app!.handle(.control(19))
            }
            let target = method.hasSuffix("feedback") ? item.itemID : f.category.itemID
            XCTAssertEqual(try f.store.history(target).count, 2)
            XCTAssertTrue(screen(app!).contains("Unconfirmed learning edit"))
            let frozen = try XCTUnwrap(journal.loadOperation())
            guard case .learning(let request) = frozen else { return XCTFail("Wrong recovery operation") }
            app!.handle(.text("d"))
            app!.handle(.text("u"))
            XCTAssertEqual(sent.count, 1, "Unconfirmed edit locks unrelated actions")
            app = nil
            _ = try f.service.learning.reset(categoryID: f.category.itemID)
            app = try f.app(client: client, journal: journal)
            XCTAssertEqual(sent.count, 1, "Loading does not resend")
            app!.handle(.text("r"))
            XCTAssertTrue(screen(app!).contains("Recovered learning edit"))
            XCTAssertNil(try journal.loadOperation())
            XCTAssertEqual(sent.count, 2)
            XCTAssertEqual(sent[0], sent[1])
            XCTAssertEqual(try f.store.history(target).count, 2)
            XCTAssertTrue(try request.send(using: f.client).wasReplayed)
        }
    }

    func testRejectedFeedbackDoesNotEnterInfiniteRecoveryOrOverwriteConcurrentEdit() throws {
        let f = try Fixture()
        let item = try f.item("chess tournament board")
        var external: Revision?
        let client = ItemClient(transport: { data in
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if (request["methodCalls"] as! [[Any]])[0][0] as? String == "TractandaLearning/feedback",
                external == nil
            {
                external = try f.revise(item, ["subject": .text("Concurrent edit wins")])
            }
            return f.service.handle(data, peerUID: f.store.ownerUID)
        })
        let journal = f.journal()
        let app = try f.app(client: client, journal: journal)
        open(app)
        app.handle(.text("t"))
        app.handle(.text("a"))
        XCTAssertTrue(screen(app).contains("revisionConflict"))
        XCTAssertNil(try journal.loadOperation())
        XCTAssertEqual(try f.store.get(item.itemID), external)
        XCTAssertNil(external?.fields["learningFeedback"])
    }

    func testMenuEntryOpensSelectedCategoryWithoutAccumulatingItemFilters() throws {
        let f = try Fixture()
        _ = try f.item("chess tournament board")
        let app = try f.app()
        app.handle(.text("c"))
        app.handle(.paste("Club café"))
        app.handle(.function(10))
        for _ in 0..<5 { app.handle(.right) }
        // Menus with no commands are skipped; select Learning through its stable shortcut.
        app.handle(.modified(.text("l"), .option))
        XCTAssertTrue(screen(app).contains("Learning · Club café 文"))
        app.handle(.function(9))
        XCTAssertTrue(screen(app).contains("Category manager"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("All items"))
    }

    func testAuthorizedLearningScopesReadOnlyFeedbackAndRevocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-learning-acl-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root.appendingPathComponent("store"), accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: Identifier.make())
        let service = ItemService(store: store)
        func permissions(_ mode: Int64) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
            ])
        }
        func create(_ fields: [String: ItemValue]) throws -> Revision {
            try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
                ).revision
            }
        }
        let category = try create([
            "subject": .text("Readable Club"), "permissions": permissions(0o640),
            "selection": .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
            ]),
        ])
        for (words, label) in [
            ("chess tournament players", "include"), ("chess board players", "include"),
            ("garden vegetables soil", "exclude"), ("garden flowers soil", "exclude"),
        ] {
            _ = try create([
                "subject": .text(words), "permissions": permissions(0o640),
                "categoryOverrides": .object([category.itemID: .text(label)]),
            ])
        }
        _ = try create([
            "subject": .text("PRIVATE TRAINING chess players"), "permissions": permissions(0o600),
            "categoryOverrides": .object([category.itemID: .text("include")]),
        ])
        let candidate = try create([
            "subject": .text("chess tournament board"), "permissions": permissions(0o640),
        ])
        let aliceModel = try store.withAccess(forUID: accounts.alice) {
            try service.learning.train(categoryID: category.itemID).modelID
        }
        let bob = ItemClient(transport: { service.handle($0, peerUID: accounts.bob) })
        let journal = RecoveryJournal(
            url: root.appendingPathComponent("bob-pending.json"), socket: "/fixture")
        let app = try TerminalApplication(client: bob, journal: journal, itemsOnly: true)
        open(app)
        app.handle(.text("t"))
        XCTAssertTrue(screen(app).contains("2 positive"))
        XCTAssertFalse(screen(app).contains("PRIVATE TRAINING"))
        app.handle(.text("a"))
        XCTAssertTrue(screen(app).contains("forbidden"))
        XCTAssertNil(try journal.loadOperation())
        XCTAssertEqual(try store.get(candidate.itemID), candidate)
        app.handle(.text("r"))
        app.handle(.text("u"))
        app.handle(.text("reset"))
        app.handle(.control(19))
        XCTAssertEqual(
            try store.withAccess(forUID: accounts.alice) {
                try service.learning.status(for: category.itemID).modelID
            }, aliceModel, "Bob's reset does not reset Alice's model")
        app.handle(.text("t"))
        _ = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: candidate.itemID,
                    expectedRevisionID: candidate.revisionID, changes: ["permissions": permissions(0o600)],
                    operationID: Identifier.make()))
        }
        app.handle(.text("a"))
        XCTAssertFalse(screen(app).contains("chess tournament board"))
        XCTAssertNil(try store.get(candidate.itemID).fields["learningFeedback"])
        app.handle(.text("r"))
        app.handle(.text("e"))
        XCTAssertFalse(screen(app).contains("PRIVATE TRAINING"))
        XCTAssertFalse(screen(app).contains("chess tournament board"))
    }
}
