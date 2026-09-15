import Foundation

public enum DemoFixture {
    /// Stable operation IDs make seeding repeatable without overwriting later edits.
    public static func seed(_ store: ItemStore) throws -> [String: String] {
        func create(_ name: String, _ type: String, _ fields: [String: ItemValue]) throws -> Revision {
            try store.commit(CommitRequest(classID: type, changes: fields, operationID: "fixture-v1-\(name)"))
                .revision
        }
        func selection(_ expression: String) -> ItemValue {
            .object(["language": .text(SpotlightQuery.profile), "expression": .text(expression)])
        }
        let alice = try create(
            "alice", "NaturalPersonItem",
            [
                "subject": .text("Alice"),
                "displayName": .text("Alice"), "mobilePhone": .text("+43 000 111111"),
                "selection": selection("associatedPerson == \"alice\""),
            ])
        let bob = try create(
            "bob", "NaturalPersonItem",
            [
                "subject": .text("Bob"),
                "displayName": .text("Bob"), "mobilePhone": .text("+43 000 222222"),
            ])
        func holding(_ name: String, _ person: Revision, _ start: String, _ end: String? = nil) -> ItemValue {
            var fields: [String: ItemValue] = [
                "key": .text(name), "holder": .reference(ItemReference(person.itemID)), "start": .date(start),
            ]
            if let end { fields["end"] = .date(end) }
            return .object(fields)
        }
        let role = try create(
            "president", "RoleItem",
            [
                "subject": .text("President of the chess club"),
                "phone": .text("+43 000 900000"), "officeNumber": .text("Room 12"),
                "holdings": .list([
                    holding("alice-term", alice, "2020-01-01T00:00:00Z", "2025-01-01T00:00:00Z"),
                    holding("bob-term", bob, "2025-02-01T00:00:00Z"),
                ]),
            ])
        let persons = try create(
            "persons", "NoteItem",
            [
                "subject": .text("Associated with persons"),
                "selection": selection("associatedPerson == *"),
            ])
        let family = try create(
            "family", "NoteItem",
            [
                "subject": .text("Family"),
                "selection": selection("context == \"family\""),
            ])
        let lunch = try create(
            "lunch", "NoteItem",
            [
                "subject": .text("Family lunch with Alice"),
                "body": .text("Discuss the chess club newsletter over lunch."),
                "associatedPerson": .text("alice"), "context": .text("family"),
            ])
        let work = try create(
            "work", "NoteItem",
            [
                "subject": .text("Newsletter delivery issue"),
                "body": .text("Alice reported a missing chess club newsletter."),
                "associatedPerson": .text("alice"), "context": .text("work"),
            ])
        let todo = try create(
            "todo", "TodoItem",
            [
                "subject": .text("Arrange the next general assembly"),
                "body": .text("Confirm a date with the president."),
                "role": .reference(ItemReference(role.itemID)),
            ])
        return [
            "alice": alice.itemID, "bob": bob.itemID, "president": role.itemID,
            "persons": persons.itemID, "family": family.itemID, "lunch": lunch.itemID,
            "issue": work.itemID, "todo": todo.itemID,
        ]
    }
}
