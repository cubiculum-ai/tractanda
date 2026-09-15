import CTractandaTerminal
import Foundation

indirect enum TerminalKey: Equatable, Sendable {
    case text(String)
    case paste(String)
    case control(UInt8)
    case function(Int)
    case modified(TerminalKey, KeyModifiers)
    case mouse(TerminalMouseEvent)
    case up, down, left, right, home, end, pageUp, pageDown, tab, backTab
    case enter, backspace, delete, insert, escape, ignored
}

/// Incremental UTF-8/VT input. Pasted bytes never become commands, even after overflow.
struct TerminalInput {
    private var bytes: [UInt8] = []
    private var paste: [UInt8]? = nil
    private var isPasteTooLarge = false
    private var terminalReplies: [String] = []
    private var discardingTerminalReply: Bool?
    var isAwaitingEscape: Bool {
        paste == nil && bytes.first == 27 && !bytes.starts(with: [27, 91, 77])
            && !bytes.starts(with: [27, 91, 60])
    }
    static let maximumPaste = 65_536
    private static let maximumTerminalReply = 1_024

    mutating func takeTerminalReplies() -> [String] {
        defer { terminalReplies = [] }
        return terminalReplies
    }

    mutating func receive(_ input: [UInt8], expireEscape: Bool = false) -> [TerminalKey] {
        bytes.append(contentsOf: input)
        var keys: [TerminalKey] = []
        var index = 0
        let pasteEnd: [UInt8] = [27, 91, 50, 48, 49, 126]
        while index < bytes.count {
            if let isOSC = discardingTerminalReply {
                if let end = Self.terminalReplyEnd(in: bytes, start: index, isOSC: isOSC) {
                    index = end + 1
                    discardingTerminalReply = nil
                    continue
                }
                // Preserve only a split ESC of a possible ST; an oversized protocol reply must
                // never later be decoded as user text.
                if bytes.count - index > Self.maximumTerminalReply {
                    bytes = bytes.last == 27 ? [27] : []
                    index = 0
                }
                break
            }
            let remaining = bytes[index...]
            if paste != nil {
                if remaining.starts(with: pasteEnd) {
                    keys.append(isPasteTooLarge ? .ignored : .paste(String(decoding: paste!, as: UTF8.self)))
                    paste = nil
                    isPasteTooLarge = false
                    index += pasteEnd.count
                } else if pasteEnd.starts(with: remaining) {
                    break
                } else {
                    if paste!.count < Self.maximumPaste {
                        paste!.append(bytes[index])
                    } else {
                        isPasteTooLarge = true
                    }
                    index += 1
                }
                continue
            }
            let byte = bytes[index]
            if byte == 27 {
                if remaining.count == 1 {
                    if expireEscape {
                        keys.append(.escape)
                        index += 1
                    }
                    break
                }
                if bytes[index + 1] == 93 || bytes[index + 1] == 80 {
                    // OSC/DCS responses are terminal protocol, never text input.  Both forms may
                    // arrive fragmented; cap them so a hostile or broken terminal cannot retain
                    // arbitrary input indefinitely.
                    let isOSC = bytes[index + 1] == 93
                    guard let end = Self.terminalReplyEnd(in: bytes, start: index + 2, isOSC: isOSC)
                    else {
                        if remaining.count > Self.maximumTerminalReply {
                            discardingTerminalReply = isOSC
                            index = bytes.count
                        }
                        break
                    }
                    if end - index + 1 <= Self.maximumTerminalReply {
                        terminalReplies.append(String(decoding: bytes[index...end], as: UTF8.self))
                    }
                    index = end + 1
                } else if bytes[index + 1] == 91 || bytes[index + 1] == 79 {
                    // Legacy mouse reports have three raw bytes after CSI M. Consume them as a
                    // unit, even when SGR reporting was requested but the terminal ignored it.
                    if remaining.starts(with: [27, 91, 77]) {
                        guard remaining.count >= 6 else {
                            break
                        }
                        keys.append(
                            TerminalMouseEvent.decode(
                                code: Int(bytes[index + 3]) - 32, x: Int(bytes[index + 4]) - 32,
                                y: Int(bytes[index + 5]) - 32, release: false, legacy: true))
                        index += 6
                        continue
                    }
                    guard let final = bytes[(index + 2)...].firstIndex(where: { (64...126).contains($0) })
                    else {
                        if remaining.count > 64 || (expireEscape && !remaining.starts(with: [27, 91, 60])) {
                            index = bytes.count
                            keys.append(.ignored)
                        }
                        break
                    }
                    let code = String(decoding: bytes[index...final], as: UTF8.self)
                    if code == "\u{1b}[200~" {
                        paste = []
                        isPasteTooLarge = false
                    } else {
                        keys.append(Self.decodeSequence(code))
                    }
                    index = final + 1
                } else {
                    // Meta is conventionally an Escape prefix. Keep fragmented UTF-8 intact.
                    let next = bytes[index + 1]
                    if next == 27 {
                        if remaining.dropFirst().starts(with: [27, 91, 77]) {
                            keys.append(.escape)
                            index += 1
                            continue
                        }
                        if remaining.count == 2 && !expireEscape { break }
                        if remaining.count > 2, bytes[index + 2] == 91 || bytes[index + 2] == 79 {
                            guard
                                let final = bytes[(index + 3)...].firstIndex(where: {
                                    (64...126).contains($0)
                                })
                            else {
                                if remaining.count > 64 || expireEscape {
                                    keys.append(.ignored)
                                    index = bytes.count
                                }
                                break
                            }
                            let key = Self.decodeSequence(
                                String(decoding: bytes[(index + 1)...final], as: UTF8.self))
                            keys.append(.modified(key, .option))
                            index = final + 1
                            continue
                        }
                    }
                    let length = Self.utf8Length(next)
                    guard remaining.count >= length + 1 else { break }
                    var decoder = TerminalInput()
                    let decoded = decoder.receive(
                        Array(bytes[(index + 1)..<(index + 1 + length)]), expireEscape: true)
                    keys.append(decoded.first.map { .modified($0, .option) } ?? .ignored)
                    index += 1 + length
                }
                continue
            }
            let singles: [UInt8: TerminalKey] = [
                9: .tab, 10: .enter, 13: .enter, 8: .backspace, 127: .backspace,
            ]
            if let key = singles[byte] {
                keys.append(key)
                index += 1
                continue
            }
            if byte < 32 {
                keys.append(.control(byte))
                index += 1
                continue
            }
            let length = Self.utf8Length(byte)
            guard remaining.count >= length else { break }
            if let text = String(bytes: bytes[index..<(index + length)], encoding: .utf8) {
                keys.append(.text(text))
                index += length
            } else {
                keys.append(.text("�"))
                index += 1
            }
        }
        bytes.removeFirst(index)
        return keys
    }

    /// The final byte of the earliest complete BEL or ST terminator.
    private static func terminalReplyEnd(in bytes: [UInt8], start: Int, isOSC: Bool) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        while index < bytes.count {
            if isOSC, bytes[index] == 7 { return index }
            if bytes[index] == 27, index + 1 < bytes.count, bytes[index + 1] == 92 {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func utf8Length(_ byte: UInt8) -> Int {
        byte < 128 ? 1 : byte < 224 ? 2 : byte < 240 ? 3 : 4
    }

    /// Legacy VT, xterm modifiers and the CSI-u keyboard protocol share one event model.
    private static func decodeSequence(_ sequence: String) -> TerminalKey {
        if let key = escapeCodes[sequence] { return key }
        guard sequence.hasPrefix("\u{1b}["), sequence.utf8.count <= 64,
            let final = sequence.last
        else { return .ignored }
        if sequence.hasPrefix("\u{1b}[<") {
            let values = sequence.dropFirst(3).dropLast().split(
                separator: ";", omittingEmptySubsequences: false)
            guard final == "M" || final == "m", values.count == 3,
                values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
                let code = Int(values[0]), let x = Int(values[1]), let y = Int(values[2])
            else { return .ignored }
            return TerminalMouseEvent.decode(code: code, x: x, y: y, release: final == "m")
        }
        let fields = sequence.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 3 else { return .ignored }
        let codes = fields[0].split(separator: ":", omittingEmptySubsequences: false)
        guard let code = codes.first.flatMap({ Int($0) }) else { return .ignored }
        let modifierFields =
            fields.count > 1 ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
        guard modifierFields.count <= 2,
            modifierFields.isEmpty || modifierFields[0].isEmpty || Int(modifierFields[0]) != nil
        else { return .ignored }
        let encodedModifiers = modifierFields.first.flatMap { Int($0) } ?? 1
        let event = modifierFields.count > 1 ? Int(modifierFields[1]) : 1
        guard (1...256).contains(encodedModifiers), event == 1 || event == 2 else { return .ignored }
        let bits = encodedModifiers - 1
        guard bits & 16 == 0 else { return .ignored }  // Hyper has no configured meaning.
        var modifiers = KeyModifiers(rawValue: bits & 15)
        if bits & 32 != 0 { modifiers.insert(.option) }  // Meta and Option share the Emacs role.
        let key: TerminalKey
        if final == "u" {
            switch code {
            case 27, 57344: key = .escape
            case 13, 57345: key = .enter
            case 9, 57346: key = .tab
            case 127, 57347: key = .backspace
            case 57348: key = .insert
            case 57349: key = .delete
            case 57350: key = .left
            case 57351: key = .right
            case 57352: key = .up
            case 57353: key = .down
            case 57354: key = .pageUp
            case 57355: key = .pageDown
            case 57356: key = .home
            case 57357: key = .end
            case 57364...57398: key = .function(code - 57363)
            default:
                guard code >= 32, !(57344...63743).contains(code), let scalar = UnicodeScalar(code),
                    scalar.properties.generalCategory != .control
                else { return .ignored }
                if modifiers == .shift {
                    let shifted = codes.count > 1 ? Int(codes[1]).flatMap(UnicodeScalar.init) : nil
                    return .text(shifted.map(String.init) ?? String(scalar).uppercased())
                }
                key = .text(String(scalar))
            }
        } else {
            let plain = final == "~" ? "\u{1b}[\(code)~" : "\u{1b}[\(final)"
            guard final == "~" || code == 1, let decoded = escapeCodes[plain] else { return .ignored }
            key = decoded
        }
        if modifiers.isEmpty { return key }
        if key == .tab && modifiers == .shift { return .backTab }
        return .modified(key, modifiers)
    }

    private static let escapeCodes: [String: TerminalKey] = [
        "\u{1b}[A": .up, "\u{1b}[B": .down, "\u{1b}[C": .right, "\u{1b}[D": .left,
        "\u{1b}OA": .up, "\u{1b}OB": .down, "\u{1b}OC": .right, "\u{1b}OD": .left,
        "\u{1b}[H": .home, "\u{1b}[F": .end, "\u{1b}OH": .home, "\u{1b}OF": .end,
        "\u{1b}[1~": .home, "\u{1b}[4~": .end, "\u{1b}[7~": .home, "\u{1b}[8~": .end,
        "\u{1b}[3~": .delete, "\u{1b}[5~": .pageUp, "\u{1b}[6~": .pageDown,
        "\u{1b}[2~": .insert,
        "\u{1b}[Z": .backTab, "\u{1b}OP": .function(1), "\u{1b}OQ": .function(2),
        "\u{1b}[P": .function(1), "\u{1b}[Q": .function(2), "\u{1b}[S": .function(4),
        "\u{1b}OR": .function(3), "\u{1b}OS": .function(4), "\u{1b}[11~": .function(1),
        "\u{1b}[12~": .function(2), "\u{1b}[13~": .function(3), "\u{1b}[14~": .function(4),
        "\u{1b}[15~": .function(5), "\u{1b}[17~": .function(6), "\u{1b}[18~": .function(7),
        "\u{1b}[19~": .function(8), "\u{1b}[20~": .function(9), "\u{1b}[21~": .function(10),
        "\u{1b}[23~": .function(11), "\u{1b}[24~": .function(12),
    ]
}

enum TerminalText {
    static func safe(_ text: String, multiline: Bool = false) -> String {
        String(
            text.unicodeScalars.map { scalar -> Character in
                if scalar == "\n" && multiline { return "\n" }
                if scalar == "\t" { return " " }
                if scalar.properties.generalCategory == .control
                    || (scalar.properties.generalCategory == .format && scalar.value != 0x200D)
                {
                    return "�"
                }
                return Character(String(scalar))
            })
    }

    static func width(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) { return 2 }
        return max(1, scalars.map { max(0, Int(tractanda_terminal_width($0.value))) }.max() ?? 1)
    }

    static func fit(_ text: String, columns: Int) -> String {
        var result = ""
        var used = 0
        for character in safe(text) {
            let size = width(character)
            if used + size > columns { break }
            result.append(character)
            used += size
        }
        return result + String(repeating: " ", count: max(0, columns - used))
    }

    static func lines(_ text: String, columns: Int) -> [String] {
        guard columns > 0 else { return [] }
        var lines = [String]()
        var line = ""
        var used = 0
        for character in safe(text, multiline: true) {
            if character == "\n" {
                lines.append(line)
                line = ""
                used = 0
                continue
            }
            let size = width(character)
            if used + size > columns {
                lines.append(line)
                line = ""
                used = 0
            }
            line.append(character)
            used += size
        }
        lines.append(line)
        return lines
    }
}
