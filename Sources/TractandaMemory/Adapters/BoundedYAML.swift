import CYaml
import Foundation
import TractandaCore
import Yams

/// Parser limits apply to libyaml events before Yams recursively constructs a tree.
/// Completed acyclic anchors are supported only within expanded-tree bounds. Forward/self
/// aliases are rejected before composition, as are expansions that exceed any bound.
enum BoundedYAML {
    static let maximumDepth = 20
    static let maximumNodes = 16_384
    static let maximumBytes = 512 * 1024

    private struct Cost {
        var nodes = 1
        var bytes = 0
        var depth = 1
    }

    private struct Frame {
        var anchor: String?
        var cost = Cost()
    }

    private static func anchor(_ pointer: UnsafePointer<UInt8>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    static func parse(_ text: String) throws -> Node {
        let bytes = Array(text.utf8)
        guard bytes.count <= maximumBytes else {
            throw TractandaError("importYAMLLimit", "YAML frontmatter exceeds its byte bound.")
        }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else {
            throw TractandaError("importYAML", "Could not initialize the YAML parser.")
        }
        defer { yaml_parser_delete(&parser) }
        try bytes.withUnsafeBufferPointer { buffer in
            yaml_parser_set_input_string(&parser, buffer.baseAddress, buffer.count)
            var nodes = 0
            var scalarBytes = 0
            var documents = 0
            var aliases = 0
            var frames: [Frame] = []
            var anchors: [String: Cost] = [:]
            func include(_ cost: Cost) throws {
                guard cost.nodes <= maximumNodes, cost.bytes <= maximumBytes * 2,
                    cost.depth + frames.count <= maximumDepth
                else {
                    throw TractandaError("importYAMLLimit", "YAML expanded alias tree exceeds parser bounds.")
                }
                if !frames.isEmpty {
                    frames[frames.count - 1].cost.nodes += cost.nodes
                    frames[frames.count - 1].cost.bytes += cost.bytes
                    frames[frames.count - 1].cost.depth = max(
                        frames[frames.count - 1].cost.depth, cost.depth + 1)
                }
            }
            var finished = false
            while !finished {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else {
                    throw TractandaError(
                        "importYAML", "Malformed YAML frontmatter; original bytes are unchanged.")
                }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_ALIAS_EVENT:
                    aliases += 1
                    guard aliases <= 1024, let name = anchor(event.data.alias.anchor),
                        let cost = anchors[name]
                    else {
                        throw TractandaError(
                            "importYAMLAliasUnsupported",
                            "Unresolved, self-referential or excessive YAML aliases are unsupported; original bytes are unchanged."
                        )
                    }
                    nodes += cost.nodes
                    scalarBytes += cost.bytes
                    try include(cost)
                case YAML_MAPPING_START_EVENT, YAML_SEQUENCE_START_EVENT:
                    nodes += 1
                    let name =
                        event.type == YAML_MAPPING_START_EVENT
                        ? anchor(event.data.mapping_start.anchor) : anchor(event.data.sequence_start.anchor)
                    frames.append(Frame(anchor: name))
                case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT:
                    guard let frame = frames.popLast() else {
                        throw TractandaError("importYAML", "Unbalanced YAML container.")
                    }
                    try include(frame.cost)
                    if let name = frame.anchor { anchors[name] = frame.cost }
                case YAML_SCALAR_EVENT:
                    nodes += 1
                    let cost = Cost(bytes: event.data.scalar.length)
                    scalarBytes += cost.bytes
                    try include(cost)
                    if let name = anchor(event.data.scalar.anchor) { anchors[name] = cost }
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                case YAML_STREAM_END_EVENT:
                    finished = true
                default: break
                }
                guard frames.count <= maximumDepth, nodes <= maximumNodes,
                    scalarBytes <= maximumBytes * 2, documents <= 1
                else {
                    throw TractandaError(
                        "importYAMLLimit", "YAML exceeds the depth, node or single-document bound.")
                }
            }
        }
        // No generic/custom object constructors are invoked. Conversion below inspects
        // node tags and uses only the library's built-in scalar conversions.
        guard let node = try Yams.compose(yaml: text, .default, .default, .utf8) else {
            throw TractandaError("importYAML", "Empty YAML frontmatter.")
        }
        return node
    }

    static func value(_ node: Node, diagnostics: inout [ImportDiagnostic], depth: Int = 0) -> ItemValue {
        guard depth < 24 else {
            diagnostics.append(
                .init(
                    "yamlValueDepthCarried",
                    "A YAML value exceeding native projection depth is retained only in original/frontmatter bytes.",
                    severity: .unsupported))
            return .object(["carriedInOriginal": .boolean(true)])
        }
        let tag = node.tag.rawValue
        let standardPrefix = "tag:yaml.org,2002:"
        if !tag.hasPrefix(standardPrefix) {
            diagnostics.append(
                .init(
                    "yamlTagCarried", "Custom YAML tag \(tag) is carried as inert data.",
                    severity: .unsupported))
            return .object([
                "yamlTag": .text(tag), "value": untagged(node, diagnostics: &diagnostics, depth: depth + 1),
            ])
        }
        return untagged(node, diagnostics: &diagnostics, depth: depth)
    }

    private static func untagged(_ node: Node, diagnostics: inout [ImportDiagnostic], depth: Int) -> ItemValue
    {
        switch node {
        case .scalar(let scalar):
            switch node.tag.rawValue {
            case "tag:yaml.org,2002:bool":
                if let value = node.bool { return .boolean(value) }
            case "tag:yaml.org,2002:int":
                if let value = node.int { return .integer(Int64(value)) }
                diagnostics.append(
                    .init(
                        "yamlNumberCarried", "An integer outside the native range is retained as text.",
                        severity: .unsupported))
            case "tag:yaml.org,2002:float":
                if let value = node.float, value.isFinite { return .real(value) }
                diagnostics.append(
                    .init(
                        "yamlNumberCarried", "A non-finite or unrepresentable number is retained as text.",
                        severity: .unsupported))
            case "tag:yaml.org,2002:null":
                diagnostics.append(
                    .init(
                        "yamlNullCarried", "YAML null is retained with a type marker.", severity: .information
                    ))
                return .object(["yamlTag": .text("tag:yaml.org,2002:null"), "value": .text(scalar.string)])
            default: break
            }
            return .text(scalar.string)
        case .sequence(let sequence):
            return .list(sequence.map { value($0, diagnostics: &diagnostics, depth: depth + 1) })
        case .mapping(let mapping):
            var result: [String: ItemValue] = [:]
            var complex: [ItemValue] = []
            for (key, node) in mapping {
                if case .scalar(let scalar) = key, key.tag.rawValue == "tag:yaml.org,2002:str",
                    !scalar.string.isEmpty, !scalar.string.contains("\0"),
                    result[scalar.string] == nil
                {
                    result[scalar.string] = value(node, diagnostics: &diagnostics, depth: depth + 2)
                } else {
                    complex.append(
                        .object([
                            "key": value(key, diagnostics: &diagnostics, depth: depth + 3),
                            "value": value(node, diagnostics: &diagnostics, depth: depth + 3),
                        ]))
                }
            }
            if !complex.isEmpty {
                diagnostics.append(
                    .init(
                        "yamlComplexKeysCarried",
                        "YAML mapping entries with non-string keys are carried as key/value records.",
                        severity: .unsupported))
                // A wrapper avoids collisions with source extension keys.
                return .object(["stringKeys": .object(result), "otherEntries": .list(complex)])
            }
            return .object(result)
        case .alias:
            // Yams resolves supported acyclic aliases to nodes during composition.
            return .object(["unsupportedYAMLAlias": .boolean(true)])
        }
    }
}
