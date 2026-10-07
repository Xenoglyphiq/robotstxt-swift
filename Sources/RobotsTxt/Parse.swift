// Spec operation `parse` (§3.1). Works on UTF-8 bytes; never fails.

private let lf: UInt8 = 0x0A, cr: UInt8 = 0x0D, space: UInt8 = 0x20, tab: UInt8 = 0x09
private let hash: UInt8 = 0x23, colon: UInt8 = 0x3A

/// Spec operation `parse`: parses a robots.txt file. Lenient: **never fails**.
///
/// Only the first `limits.maxBytes` bytes are read. Past the limit the line it cuts
/// is dropped and `truncated` is set (spec D-005). A UTF-8 byte order mark, or a
/// prefix of one, at the start is skipped. Lines end at `\r\n`, `\n` or a lone `\r`.
public func parse(_ data: some Collection<UInt8>, limits: Limits = Limits()) -> RobotsFile {
    let max = Int(clamping: limits.maxBytes)
    var bytes = Array(data.prefix(max))
    var truncated = false
    if bytes.count == max, data.count > max {
        truncated = true
        // Drop the bytes after the last line terminator: the line the limit cut.
        if let last = bytes.lastIndex(where: { $0 == lf || $0 == cr }) {
            bytes.removeSubrange((last + 1)...)
        } else {
            bytes.removeAll()
        }
    }
    return bytes.withUnsafeBufferPointer {
        var parser = Parser(bytes: $0)
        return parser.run(truncated: truncated)
    }
}

/// Spec operation `parse` on text: the same as parsing `text.utf8`.
public func parse(_ text: String, limits: Limits = Limits()) -> RobotsFile {
    parse(text.utf8, limits: limits)
}

private enum Key {
    case userAgent, allow, disallow, crawlDelay, sitemap, other

    init(_ key: UnsafeBufferPointer<UInt8>.SubSequence) {
        func equals(_ name: StaticString) -> Bool {
            guard key.count == name.utf8CodeUnitCount else { return false }
            let n = name.utf8Start
            var i = 0
            for b in key {
                // ASCII case-insensitive: fold A-Z to a-z. Names are lower-case.
                let folded = b >= 0x41 && b <= 0x5A ? b | 0x20 : b
                if folded != n[i] { return false }
                i += 1
            }
            return true
        }
        if equals("user-agent") { self = .userAgent }
        else if equals("allow") { self = .allow }
        else if equals("disallow") { self = .disallow }
        else if equals("crawl-delay") { self = .crawlDelay }
        else if equals("sitemap") { self = .sitemap }
        else { self = .other }
    }
}

private struct Parser {
    typealias Slice = UnsafeBufferPointer<UInt8>.SubSequence
    let bytes: UnsafeBufferPointer<UInt8>

    var groups: [Group] = []
    var sitemaps: [String] = []
    /// Whether the last group's agent list is still open (a `user-agent` line adds to it).
    var agentListOpen = false

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func run(truncated: Bool) -> RobotsFile {
        let n = bytes.count
        // Byte order mark EF BB BF, or a prefix of it.
        var i = 0
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        while i < 3, i < n, bytes[i] == bom[i] { i += 1 }

        var line = 0
        while i < n {
            var j = i
            while j < n, bytes[j] != lf, bytes[j] != cr { j += 1 }
            line += 1
            record(bytes[i..<j], line: UInt32(clamping: line))
            if j < n {
                j += bytes[j] == cr && j + 1 < n && bytes[j + 1] == lf ? 2 : 1
            }
            i = j
        }
        return RobotsFile(groups: groups, sitemaps: sitemaps, truncated: truncated)
    }

    static func trim(_ s: Slice) -> Slice {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi, s[lo] == space || s[lo] == tab { lo += 1 }
        while hi > lo, s[hi - 1] == space || s[hi - 1] == tab { hi -= 1 }
        return s[lo..<hi]
    }

    /// Splits a line into key and value (spec §3.1 step 4), or nil to skip it.
    static func keyValue(_ raw: Slice) -> (Slice, Slice)? {
        var s = raw
        if let h = s.firstIndex(of: hash) { s = s[s.startIndex..<h] }
        s = trim(s)
        if s.isEmpty { return nil }
        let key: Slice, value: Slice
        if let c = s.firstIndex(of: colon) {
            key = s[s.startIndex..<c]
            value = s[(c + 1)...]
        } else {
            // No colon: exactly two space- or tab-separated words (D-006).
            guard let gap = s.firstIndex(where: { $0 == space || $0 == tab }) else { return nil }
            let second = trim(s[gap...])
            guard !second.contains(where: { $0 == space || $0 == tab }) else { return nil }
            key = s[s.startIndex..<gap]
            value = second
        }
        let k = trim(key)
        if k.isEmpty { return nil }
        return (k, trim(value))
    }

    mutating func record(_ raw: Slice, line: UInt32) {
        guard let (key, value) = Parser.keyValue(raw) else { return }
        switch Key(key) {
        case .userAgent:
            if groups.isEmpty || !agentListOpen {
                groups.append(Group(userAgents: []))
                agentListOpen = true
            }
            groups[groups.count - 1].userAgents.append(String(decoding: value, as: UTF8.self))
        case .allow, .disallow:
            guard !groups.isEmpty else { return }
            agentListOpen = false
            if !value.isEmpty {
                let rule = Rule(allow: Key(key) == .allow, raw: ArraySlice(value), line: line)
                groups[groups.count - 1].rules.append(rule)
            }
        case .crawlDelay:
            guard !groups.isEmpty else { return }
            agentListOpen = false
            if groups[groups.count - 1].crawlDelay == nil, let delay = Parser.decimal(value) {
                groups[groups.count - 1].crawlDelay = delay
            }
        case .sitemap:
            if !value.isEmpty { sitemaps.append(String(decoding: value, as: UTF8.self)) }
        case .other:
            break
        }
    }

    /// A non-negative decimal, `[0-9]+(\.[0-9]+)?`, as seconds; nil for anything else.
    static func decimal(_ s: Slice) -> Double? {
        var i = s.startIndex
        func digits() -> Int {
            let start = i
            while i < s.endIndex, s[i] >= 0x30, s[i] <= 0x39 { i += 1 }
            return i - start
        }
        guard digits() > 0 else { return nil }
        if i < s.endIndex {
            guard s[i] == 0x2E else { return nil }
            i += 1
            guard digits() > 0, i == s.endIndex else { return nil }
        }
        return Double(String(decoding: s, as: UTF8.self))
    }
}
