import Foundation

public protocol ItemProtocol: AnyObject {
    var revision: Revision { get }
    subscript(key: String) -> ItemValue? { get }
}
/// An optional view-definition capability shared by every item class.
/// `Item` provides the fixed conformance; subclasses inherit it without changing identity or class.
public protocol SavedView: ItemProtocol {
    var viewDefinition: SavedViewDefinition? { get throws }
}
open class Item: SavedView {
    public let revision: Revision
    public required init(_ revision: Revision) { self.revision = revision }
    public subscript(key: String) -> ItemValue? { revision.fields[key] }
    public var subject: String { self["subject"]?.string ?? "" }
    public var body: String { self["body"]?.string ?? "" }
    public var viewDefinition: SavedViewDefinition? {
        get throws {
            try self["viewDefinition"].map(SavedViewDefinition.init)
        }
    }
}
open class MessageItem: Item {}
open class InternetMessageItem: MessageItem {}
public final class EmailMessageItem: InternetMessageItem {}
public final class NetnewsMessageItem: InternetMessageItem {}
public final class XMPPMessageItem: MessageItem {}
open class PersonItem: Item {}
public final class NaturalPersonItem: PersonItem {}
public final class LegalPersonItem: PersonItem {}
public final class RoleItem: PersonItem {}
open class CalendarItem: Item {}
public final class DeadlineItem: CalendarItem {}
public final class AppointmentItem: CalendarItem {}
open class MetaItem: Item {}
public final class PersonalStateItem: MetaItem {}
public final class AccessConfigurationItem: MetaItem {}

public enum ItemTypes {
    public static let parents: [String: String] = [
        "MessageItem": "Item", "InternetMessageItem": "MessageItem",
        "EmailMessageItem": "InternetMessageItem", "NetnewsMessageItem": "InternetMessageItem",
        "XMPPMessageItem": "MessageItem",
        "PersonItem": "Item", "NaturalPersonItem": "PersonItem", "LegalPersonItem": "PersonItem",
        "RoleItem": "PersonItem", "CalendarItem": "Item", "DeadlineItem": "CalendarItem",
        "AppointmentItem": "CalendarItem", "MetaItem": "Item",
        "PersonalStateItem": "MetaItem",
        "AccessConfigurationItem": "MetaItem",
    ]
    public static let abstract: Set<String> = [
        "MessageItem", "InternetMessageItem", "PersonItem",
        "CalendarItem", "MetaItem",
    ]
    public static func ancestry(_ name: String) -> [String] {
        var result = [name]
        while let parent = parents[result.last!] { result.append(parent) }
        if result.last != "Item" { result.append("Item") }
        return result
    }
    public static func makeItem(from revision: Revision) -> Item {
        let type: Item.Type
        switch revision.classID {
        case "Item": type = Item.self
        case "EmailMessageItem": type = EmailMessageItem.self
        case "NetnewsMessageItem": type = NetnewsMessageItem.self
        case "XMPPMessageItem": type = XMPPMessageItem.self
        case "NaturalPersonItem": type = NaturalPersonItem.self
        case "LegalPersonItem": type = LegalPersonItem.self
        case "RoleItem": type = RoleItem.self
        case "DeadlineItem": type = DeadlineItem.self
        case "AppointmentItem": type = AppointmentItem.self
        case "PersonalStateItem": type = PersonalStateItem.self
        case "AccessConfigurationItem": type = AccessConfigurationItem.self
        default: type = Item.self
        }
        return type.init(revision)
    }
}
