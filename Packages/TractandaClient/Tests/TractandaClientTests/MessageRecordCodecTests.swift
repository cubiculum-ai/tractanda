import Foundation
import XCTest

@testable import TractandaClient

final class MessageRecordCodecTests: XCTestCase {
    private let a = "10000000-0000-1000-8000-000000000001"
    private let b = "10000000-0000-1000-8000-000000000002"
    private let c = "10000000-0000-1000-8000-000000000003"

    private func revision(_ extras: [String: ItemValue] = [:], authored: Bool = false) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(a), "revisionID": .text(b), "classID": .text("Note"),
            "schemaVersion": .integer(1), "actor": .text("user:alice"),
            "createdAt": .date("2026-11-03T10:00:00Z"), "modifiedAt": .date("2026-11-03T10:01:00.000Z"),
            "operationID": .text("private-fixture"), "requestIdentity": .text("fixture \\ identity\n"),
        ]
        fields.merge(extras) { _, new in new }
        if authored {
            let managed: Set<String> = [
                "itemID", "revisionID", "createdAt", "modifiedAt", "actor", "operationID", "requestIdentity",
            ]
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: c, parents: [],
                writtenFields: fields.keys.filter { !managed.contains($0) }.sorted(), unsetFields: [],
                frontier: []
            ).itemValue
        }
        return try Revision(fields: fields, formatVersion: authored ? 2 : 1)
    }

    func testRawBodyAndTypedTreeRoundTripBothLogicalVersions() throws {
        let body = "\u{feff}<p>e\u{301} 🔍</p>\r\n\nlast line without a terminator"
        let fields: [String: ItemValue] = [
            "subject": .text("  control\t\r\n  "), "body": .text(body), "bodyMediaType": .text("text/html"),
            "isDeleted": .boolean(false),
            "custom": .object([
                "quoted \" / \\ e\u{301}": .list([
                    .text("line\n\u{0}\\u{a}"), .integer(.min),
                    .integer(.max), .real(-0.0), .real(Double.leastNonzeroMagnitude), .boolean(true),
                    .date("2026-11-03T10:00:00.123Z"), .reference(ItemReference(a, revisionID: c)),
                    .bytes(Data([0, 1, 255])), .bytes(Data()), .list([]), .object([:]),
                ]),
                "Ω": .text("  "), "A": .text("ASCII"),
            ]),
        ]
        for authored in [false, true] {
            let original = try revision(fields, authored: authored)
            let bytes = try MessageRecordCodec.encode(original)
            let split = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
            XCTAssertEqual(Data(bytes[split.upperBound...]), Data(body.utf8))
            let output = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(output.contains("Content-Type: text/html; charset=utf-8\r\n"))
            XCTAssertTrue(output.contains("X-Tractanda-Encoding: message-v1\r\n"))
            XCTAssertEqual(output.contains("X-Ancestry-Kind: authored"), authored)
            let decoded = try MessageRecordCodec.decode(bytes)
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(try MessageRecordCodec.encode(decoded), bytes)
        }
    }

    func testGoldenUTF8EncodingMatchesAcrossPlatforms() throws {
        let body = "🧪\r\n"
        let original = try revision([
            "subject": .text("A\\B"), "body": .text(body),
            "custom": .object([
                "é": .bytes(Data([255])), "a": .list([.real(-0.0), .text("e\u{301}")]), "Z": .integer(1),
            ]),
        ])
        let headers = [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: binary",
            "X-Tractanda-Encoding: message-v1",
            "X-Tractanda-Format-Version: 1",
            "X-Body-Present: true",
            "X-Body-Media-Type-Present: false",
            "X-Item-ID: \(a)",
            "X-Revision-ID: \(b)",
            "X-IsA: Note",
            "X-Actor: user:alice",
            "X-Operation-ID: private-fixture",
            #"Subject: A\B"#,
            "X-Created-At: 2026-11-03T10:00:00Z",
            "X-Modified-At: 2026-11-03T10:01:00.000Z",
            "X-Schema-Version: 1",
            #"X-Field-Object: "custom""#,
            #"X-Field-Integer: "Z" 1"#,
            #"X-Field-List: "a""#,
            "X-Field-Real: -0.0",
            "X-Field-Text: e\u{301}",
            "X-Field-End: ",
            #"X-Field-Bytes: "é" /w=="#,
            "X-Field-End: ",
            #"X-Field-Text: "requestIdentity" fixture \\ identity\n"#,
        ]
        let expected = Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        XCTAssertEqual(try MessageRecordCodec.encode(original), expected)
        XCTAssertEqual(try MessageRecordCodec.decode(expected), original)
    }

    func testBodyPresenceAndUnrecognizedMediaTypeRoundTrip() throws {
        for fields: [String: ItemValue] in [
            [:], ["body": .text("")], ["bodyMediaType": .text("unknown/example")],
            ["body": .text("# Markdown\n"), "bodyMediaType": .text("text/markdown")],
            ["body": .text("\r\n"), "bodyMediaType": .integer(7)],
        ] {
            let original = try revision(fields)
            XCTAssertEqual(try MessageRecordCodec.decode(MessageRecordCodec.encode(original)), original)
        }
    }

    func testViewProjectionPreservesDefaultsCollapseOrderAndExtensions() throws {
        let view: ItemValue = .object([
            "language": .text("tractanda.spotlight.v1"), "expression": .text("subject == 'literal'"),
            "text": .text(""),
            "categoryPath": .list([.reference(ItemReference(a))]), "excludedCategoryIDs": .list([]),
            "referenceLabels": .object([a: .text("Tractanda"), b: .text("Axis")]),
            "sort": .list([
                .object(["property": .text("modifiedAt")]),
                .object(["categoryRootID": .reference(ItemReference(b)), "isAscending": .boolean(false)]),
            ]),
            "presentation": .object([
                "profile": .text("tractanda.table.v0"),
                "columns": .list([
                    .object([
                        "property": .text("subject"), "title": .text("Süß \"Title\""), "width": .integer(40),
                    ])
                ]),
                "sections": .list([a, b, c].map { .reference(ItemReference($0)) }),
                "collapsedSections": .list([b, a].map { .reference(ItemReference($0)) }),
                "custom": .bytes(Data([23])),
            ]), "extension": .object(["nested": .list([])]),
        ])
        let original = try revision([
            "viewDefinition": view, "referenceLabels": .object([a: .text("Display only")]),
        ])
        let encoded = try MessageRecordCodec.encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("X-View-Include: \(a); label=\"Tractanda\"\r\n"))
        XCTAssertTrue(text.contains("X-View-Sort: property=modifiedAt\r\n"))
        XCTAssertTrue(text.contains("X-View-Sort: category=\(b); direction=descending; label=\"Axis\"\r\n"))
        XCTAssertTrue(
            text.contains("X-View-Column: property=subject; title=\"Süß \\\"Title\\\"\"; width=40\r\n"))
        XCTAssertTrue(text.contains("X-View-Section: \(a); collapsed=yes; collapsed-order=1\r\n"))
        XCTAssertTrue(text.contains("X-View-Section: \(b); collapsed=yes; collapsed-order=0\r\n"))
        XCTAssertTrue(text.contains("X-View-Section: \(c); collapsed=no\r\n"))
        XCTAssertEqual(try MessageRecordCodec.decode(encoded), original)
        let conflict = Data("X-View-Text: duplicate\r\n".utf8) + encoded
        XCTAssertThrowsError(try MessageRecordCodec.decode(conflict))
        let badLabel = Data("X-View-Exclude: \(a); label=\"Conflicting label\"\r\n".utf8) + encoded
        XCTAssertThrowsError(try MessageRecordCodec.decode(badLabel))
    }

    func testReadablePermissionsCategoryAndAttachmentProjection() throws {
        let attachment = try AttachmentDescriptor(
            attachmentID: c, filename: "report \"é\".txt", mediaType: "text/plain",
            byteCount: 7, sha256: String(repeating: "a", count: 64))
        let original = try revision([
            "permissions": .object([
                "profile": .text("tractanda.permissions.posix.v1"), "owner": .text("alice"),
                "group": .text("staff"), "mode": .integer(0o640), "acl": .object(["users": .object([:])]),
            ]),
            "categoryParents": .list([.reference(ItemReference(a))]),
            "categoryOverrides": .object([b: .text("exclude")]),
            "attachments": .list([attachment.itemValue]),
        ])
        let encoded = try MessageRecordCodec.encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("X-Permissions-Mode: 0640\r\n"))
        XCTAssertTrue(text.contains("X-ACL-Object: \"users\"\r\n"))
        XCTAssertTrue(text.contains("X-Category-Parent: \(a)\r\n"))
        XCTAssertTrue(text.contains("X-Attachment: \(c) \"report \\\"é\\\".txt\" text/plain 7 "))
        XCTAssertEqual(try MessageRecordCodec.decode(encoded), original)
    }

    func testUnknownHeadersAreLiteralTypedFieldsWithCollisionProtection() throws {
        let baseline = try MessageRecordCodec.encode(revision())
        let extra = Data("X-Color: red\r\nx-COLOR:  blue \r\nX-Note: literal\r\n".utf8) + baseline
        let decoded = try MessageRecordCodec.decode(extra)
        XCTAssertEqual(decoded.fields["x-color"], .list([.text("red"), .text(" blue ")]))
        XCTAssertEqual(decoded.fields["x-note"], .text("literal"))
        let canonical = try MessageRecordCodec.encode(decoded)
        XCTAssertTrue(
            String(decoding: canonical, as: UTF8.self).contains("x-color: red\r\nx-color:  blue \r\n"))
        XCTAssertEqual(try MessageRecordCodec.decode(canonical), decoded)
        let exactKeys = try revision([
            "X-Color": .text("Case-sensitive API key"),
            "x-color": .list([.text("singleton list")]),
        ])
        XCTAssertEqual(try MessageRecordCodec.decode(MessageRecordCodec.encode(exactKeys)), exactKeys)
        let typed = try MessageRecordCodec.encode(revision(["x-color": .integer(7)]))
        XCTAssertThrowsError(try MessageRecordCodec.decode(Data("X-Color: red\r\n".utf8) + typed))
        for reserved in ["X-View-Future", "X-Tractanda-Future", "Content-Transfer-Encoding"] {
            XCTAssertThrowsError(try MessageRecordCodec.decode(Data("\(reserved): x\r\n".utf8) + baseline))
        }
    }

    func testPortableFixtureCorpus() throws {
        let refA = ItemValue.reference(ItemReference(a))
        let refB = ItemValue.reference(ItemReference(b))
        let table: ItemValue = .object([
            "profile": .text("tractanda.table.v0"),
            "columns": .list([
                .object(["categoryRootID": refA, "title": .text("§ e\u{301}"), "width": .integer(18)])
            ]),
            "sections": .list([refA, refB]), "collapsedSections": .list([refB, refA]),
        ])
        let full: [String: ItemValue] = [
            "subject": .text("Über \\ e\u{301}\n  "),
            "body": .text("\u{feff}<p>猫 🧪</p>\r\n\nno final newline"), "bodyMediaType": .text("text/html"),
            "permissions": .object([
                "profile": .text("tractanda.permissions.posix.v1"), "owner": .text("alice"),
                "group": .text("staff"), "mode": .integer(0o640),
                "acl": .object([
                    "users": .object(["bob": .integer(4)]), "groups": .object([:]),
                    "mask": .integer(4), "owningGroup": .integer(4),
                ]),
            ]),
            "viewDefinition": .object([
                "language": .text("tractanda.spotlight.v1"), "expression": .text("subject == '猫'"),
                "text": .text(""),
                "categoryPath": .list([refA]), "excludedCategoryIDs": .list([refB]),
                "referenceLabels": .object([a: .text("Tractanda"), b: .text("Nested e\u{301}; \"display\"")]),
                "sort": .list([
                    .object(["property": .text("subject")]),
                    .object(["categoryRootID": refB, "isAscending": .boolean(false)]),
                ]), "presentation": table,
            ]),
            "referenceLabels": .object([a: .text("Display only")]),
            "nested": .object([
                "é": .text("prefixed e\u{301}"), "Z": .integer(.min),
                "a": .list([
                    .real(-0.0), .real(Double.leastNonzeroMagnitude), .real(Double.greatestFiniteMagnitude),
                    .date("2026-11-03T10:00:00+01:00"), .list([]), .object([:]), .bytes(Data([0, 255])),
                    .reference(ItemReference(a, revisionID: c)), .boolean(false),
                ]),
            ]),
            "x-custom": .list([.text("first"), .text("  δεύτερο  ")]),
            "requestIdentity": .text(
                Data(#"{"operationID":"fixture","changes":{"body":"Original request"}}"#.utf8)
                    .base64EncodedString()),
        ]
        let authored = try revision(full, authored: true)
        var withoutReceipt = authored.fields
        withoutReceipt["requestIdentity"] = nil
        let fixtures: [(String, Revision)] = try [
            ("legacy-absent", revision()),
            ("legacy-empty", revision(["body": .text("")])),
            (
                "markdown",
                revision(["body": .text("# Heading\n\r\n"), "bodyMediaType": .text("text/markdown")])
            ),
            ("unknown-media", revision(["body": .text("legacy"), "bodyMediaType": .text("legacy/type")])),
            ("authored-html-and-metadata", authored),
            ("authored-without-receipt", Revision(fields: withoutReceipt, formatVersion: 2)),
        ]
        let destination = ProcessInfo.processInfo.environment["TRACTANDA_MESSAGE_GOLDENS"].map {
            URL(fileURLWithPath: $0)
        }
        for (name, revision) in fixtures {
            let encoded = try MessageRecordCodec.encode(revision)
            XCTAssertEqual(try MessageRecordCodec.decode(encoded), revision)
            if let destination {
                try encoded.write(
                    to: destination.appendingPathComponent(name + ".tractanda"), options: .withoutOverwriting)
            }
        }
    }

    func testFoldedHeadersAndLiteralBackslashes() throws {
        let baseline = try MessageRecordCodec.encode(revision(["body": .text("body\r\n\tunchanged")]))
        let text = String(decoding: baseline, as: UTF8.self).replacingOccurrences(
            of: "Content-Type: text/plain; charset=utf-8",
            with: "Content-Type:\ttext/plain;\r\n\tcharset = \"UTF-8\"")
        let headers = [
            "Subject:\tFix C:\\temp \"quoted\"",
            "\tand more",
            "X-Note:C:\\temp",
            "\tplain extension",
            "X-View-Language:tractanda.spotlight.v1",
            "X-View-Expression: path == 'C:\\temp'",
            "X-View-Presentation: tractanda.table.v0",
            "X-View-Column:",
            "\tproperty = subject;",
            "\ttitle=\"A\tB\"; width = 18",
            "X-View-Sort:  property=modifiedAt;",
            " \tdirection = descending ",
        ].joined(separator: "\r\n")
        let decoded = try MessageRecordCodec.decode(Data((headers + "\r\n" + text).utf8))
        XCTAssertEqual(decoded.fields["subject"], .text("Fix C:\\temp \"quoted\"\tand more"))
        XCTAssertEqual(decoded.fields["x-note"], .text("C:\\temp\tplain extension"))
        XCTAssertEqual(decoded.fields["body"], .text("body\r\n\tunchanged"))
        let view = try XCTUnwrap(decoded.fields["viewDefinition"]?.map)
        XCTAssertEqual(view["expression"], .text("path == 'C:\\temp'"))
        XCTAssertEqual(view["presentation"]?.map?["columns"]?.array?.first?.map?["title"], .text("A\tB"))
        XCTAssertEqual(view["sort"]?.array?.first?.map?["isAscending"], .boolean(false))
        let canonical = try MessageRecordCodec.encode(decoded)
        XCTAssertTrue(
            String(decoding: canonical, as: UTF8.self).contains(
                "Subject: Fix C:\\temp \"quoted\"\tand more\r\n"))
        XCTAssertEqual(try MessageRecordCodec.decode(canonical), decoded)
    }

    func testLFHeadersPreserveMixedBodyAndLiteralUnknownText() throws {
        let body = "first\r\nsecond\nthird\rliteral"
        let original = try revision(["body": .text(body), "x-note": .text(#"literal \q"#)])
        let canonical = try MessageRecordCodec.encode(original)
        let separator = try XCTUnwrap(canonical.range(of: Data("\r\n\r\n".utf8)))
        let lfHeaders = String(decoding: canonical[..<separator.lowerBound], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let edited = Data((lfHeaders + "\n\n").utf8) + canonical[separator.upperBound...]
        let decoded = try MessageRecordCodec.decode(edited)
        XCTAssertEqual(decoded.fields["x-note"], .text(#"literal \q"#))
        XCTAssertEqual(decoded.fields["body"], .text(body))
        XCTAssertEqual(try MessageRecordCodec.encode(decoded), canonical)
        XCTAssertThrowsError(try MessageRecordCodec.decode(Data("X-Other: bare\rcontrol\n".utf8) + edited))
    }

    func testUnusualBuiltinTextUsesTypedFallbackWithoutAllowingDuplicates() throws {
        let subject = "first\r\nsecond\u{0}"
        let original = try revision(["subject": .text(subject), "x-note": .text("first\nsecond")])
        let encoded = try MessageRecordCodec.encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("Subject:"))
        XCTAssertTrue(text.contains(#"X-Field-Text: "subject" first\r\nsecond\u{0}"#))
        XCTAssertTrue(text.contains(#"X-Field-Text: "x-note" first\nsecond"#))
        XCTAssertEqual(try MessageRecordCodec.decode(encoded), original)
        XCTAssertThrowsError(try MessageRecordCodec.decode(Data("Subject: duplicate\r\n".utf8) + encoded))
    }

    func testOptionalExactReceiptCanBeRemovedWithoutChangingOtherFields() throws {
        let receipt = Data(#"{"operationID":"fixture"}"#.utf8).base64EncodedString()
        let original = try revision(
            ["body": .text("body\r\n"), "requestIdentity": .text(receipt)], authored: true)
        let encoded = try MessageRecordCodec.encode(original)
        let header = "X-Request-Identity: " + receipt + "\r\n"
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(header))
        XCTAssertEqual(try MessageRecordCodec.decode(encoded), original)
        let stripped = Data(text.replacingOccurrences(of: header, with: "").utf8)
        let decoded = try MessageRecordCodec.decode(stripped)
        var expected = original.fields
        expected["requestIdentity"] = nil
        XCTAssertEqual(decoded.fields, expected)
        XCTAssertEqual(decoded.formatVersion, original.formatVersion)
        XCTAssertEqual(try MessageRecordCodec.encode(decoded), stripped)
        XCTAssertThrowsError(try revision(["requestIdentity": .text("")]))
    }

    func testMaximumDepthAndRecordSizeRoundTrip() throws {
        var nested: ItemValue = .list([])
        for _ in 0..<31 { nested = .list([nested]) }
        let empty = try revision(["subject": .text(""), "nested": nested])
        let available = MessageRecordCodec.maximumRecordBytes - (try MessageRecordCodec.encode(empty).count)
        let subject = String(repeating: "x", count: available)
        let original = try revision(["subject": .text(subject), "nested": nested])
        let encoded = try MessageRecordCodec.encode(original)
        XCTAssertEqual(encoded.count, MessageRecordCodec.maximumRecordBytes)
        XCTAssertEqual(try MessageRecordCodec.decode(encoded), original)
        let oversized = try revision(["subject": .text(subject + "x"), "nested": nested])
        XCTAssertThrowsError(try MessageRecordCodec.encode(oversized)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
    }

    func testMalformedAndOldMessageEnvelopesFailClosed() throws {
        let original = try revision(["subject": .text("ok")])
        let bytes = try MessageRecordCodec.encode(original)
        for extra in [
            "sUBJECT: duplicate\r\n", " X-Field-Text: folded\r\n", "X-Field-End: \r\n",
            "X-Field-Object: \"unclosed\"\r\n", "X-Field-Text: \"bad\" \\u{61\r\n",
        ] {
            XCTAssertThrowsError(try MessageRecordCodec.decode(Data(extra.utf8) + bytes))
        }
        XCTAssertThrowsError(try MessageRecordCodec.decode(bytes + Data([0xff])))
        let invalidTransfer = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
            of: "Content-Transfer-Encoding: binary", with: "Content-Transfer-Encoding: 7bit")
        XCTAssertThrowsError(try MessageRecordCodec.decode(Data(invalidTransfer.utf8)))
        let withBody = try MessageRecordCodec.encode(revision(["body": .text("")]))
        XCTAssertThrowsError(try MessageRecordCodec.decode(withBody + Data([0xff])))
        let old =
            Data(
                "MIME-Version: 1.0\r\nContent-Type: application/vnd.tractanda.item+json; charset=utf-8\r\n\r\n"
                    .utf8)
            + (try JSON.encode(original))
        XCTAssertThrowsError(try MessageRecordCodec.decode(old))
    }
}
