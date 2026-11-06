import Foundation

enum MacKeyCode {
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let deleteBackward: UInt16 = 0x33
    static let escape: UInt16 = 0x35
    static let capsLock: UInt16 = 0x39

    static let f1: UInt16 = 0x7A
    static let f2: UInt16 = 0x78
    static let f3: UInt16 = 0x63
    static let f4: UInt16 = 0x76
    static let f5: UInt16 = 0x60
    static let f6: UInt16 = 0x61
    static let f7: UInt16 = 0x62
    static let f8: UInt16 = 0x64
    static let f9: UInt16 = 0x65
    static let f10: UInt16 = 0x6D
    static let f11: UInt16 = 0x67
    static let f12: UInt16 = 0x6F

    static let home: UInt16 = 0x73
    static let pageUp: UInt16 = 0x74
    static let deleteForward: UInt16 = 0x75
    static let end: UInt16 = 0x77
    static let pageDown: UInt16 = 0x79

    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E

    static func character(
        _ character: Character
    ) -> UInt16? {
        let value =
            String(character).lowercased()

        return [
            "a": 0x00,
            "s": 0x01,
            "d": 0x02,
            "f": 0x03,
            "h": 0x04,
            "g": 0x05,
            "z": 0x06,
            "x": 0x07,
            "c": 0x08,
            "v": 0x09,
            "b": 0x0B,
            "q": 0x0C,
            "w": 0x0D,
            "e": 0x0E,
            "r": 0x0F,
            "y": 0x10,
            "t": 0x11,
            "1": 0x12,
            "2": 0x13,
            "3": 0x14,
            "4": 0x15,
            "6": 0x16,
            "5": 0x17,
            "=": 0x18,
            "9": 0x19,
            "7": 0x1A,
            "-": 0x1B,
            "8": 0x1C,
            "0": 0x1D,
            "]": 0x1E,
            "o": 0x1F,
            "u": 0x20,
            "[": 0x21,
            "i": 0x22,
            "p": 0x23,
            "l": 0x25,
            "j": 0x26,
            "'": 0x27,
            "k": 0x28,
            ";": 0x29,
            "\\": 0x2A,
            ",": 0x2B,
            "/": 0x2C,
            "n": 0x2D,
            "m": 0x2E,
            ".": 0x2F,
            "`": 0x32
        ][value]
    }
}
