// Spec operations `is_allowed`, `matching_rule`, `crawl_delay` and `status_policy`
// (§3.2–§3.5). Pure functions on values: no Foundation, no I/O, no global state.

// MARK: - Normalization (§3.3 step 2, D-004)

private let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

@inline(__always) private func hexValue(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: b - 0x30
    case 0x41...0x46: b - 0x41 + 10
    case 0x61...0x66: b - 0x61 + 10
    default: nil
    }
}

/// `A-Z a-z 0-9 - . _ ~` (RFC 3986 unreserved).
@inline(__always) private func isUnreserved(_ b: UInt8) -> Bool {
    switch b {
    case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: true
    default: false
    }
}

/// Percent-encoding normalization, applied the same way to paths and patterns:
/// `%XX` of an unreserved byte is decoded, other `%XX` keep upper-case hex, and
/// bytes `0x00`–`0x20`, `0x7F` and `0x80`–`0xFF` are percent-encoded.
func normalize(_ s: some Collection<UInt8>) -> [UInt8] {
    let b = Array(s)
    var out: [UInt8] = []
    out.reserveCapacity(b.count)
    var i = 0
    while i < b.count {
        let c = b[i]
        if c == 0x25, i + 2 < b.count, let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) {
            let v = hi << 4 | lo
            if isUnreserved(v) {
                out.append(v)
            } else {
                out.append(0x25); out.append(hexDigits[Int(hi)]); out.append(hexDigits[Int(lo)])
            }
            i += 3
        } else if c <= 0x20 || c >= 0x7F {
            out.append(0x25); out.append(hexDigits[Int(c >> 4)]); out.append(hexDigits[Int(c & 0xF)])
            i += 1
        } else {
            out.append(c)
            i += 1
        }
    }
    return out
}

// MARK: - Matching (§3.3 step 3)

private let star: UInt8 = 0x2A, dollar: UInt8 = 0x24

/// Whether `pattern` matches a prefix of `path` (both normalized). `*` matches any run
/// of bytes; `$` as the pattern's last byte anchors the match at the end of the path.
///
/// Each literal piece between `*`s is placed at its leftmost occurrence after the
/// previous one. That greedy choice is always safe for `*`-only globs (an earlier
/// placement leaves every later piece more room), so there's no backtracking: the
/// cost is at most the path length times the pattern length (spec §9).
func matches(pattern: [UInt8], path: [UInt8]) -> Bool {
    pattern.withUnsafeBufferPointer { p in
        path.withUnsafeBufferPointer { s in matches(p, s) }
    }
}

private func matches(_ p: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
    var end = p.count
    let anchored = end > 0 && p[end - 1] == dollar
    if anchored { end -= 1 }

    // The first piece must match at the start of the path.
    var pi = 0
    while pi < end, p[pi] != star { pi += 1 }
    if pi == end {
        // No `*`: a plain prefix (or, anchored, the whole path).
        guard anchored ? s.count == end : s.count >= end else { return false }
        return equal(p, 0, s, 0, end)
    }
    guard s.count >= pi, equal(p, 0, s, 0, pi) else { return false }
    var si = pi

    // Pieces between `*`s: leftmost occurrence at or after `si`.
    while true {
        let start = pi + 1  // skip the `*`
        var stop = start
        while stop < end, p[stop] != star { stop += 1 }
        let len = stop - start
        if stop == end {
            // Last piece.
            if anchored {
                return s.count - si >= len && equal(p, start, s, s.count - len, len)
            }
            return len == 0 || find(p, start, len, s, from: si) != nil
        }
        if len > 0 {
            guard let at = find(p, start, len, s, from: si) else { return false }
            si = at + len
        }
        pi = stop
    }
}

@inline(__always) private func equal(
    _ p: UnsafeBufferPointer<UInt8>, _ pStart: Int, _ s: UnsafeBufferPointer<UInt8>, _ sStart: Int, _ len: Int
) -> Bool {
    var k = 0
    while k < len {
        if p[pStart + k] != s[sStart + k] { return false }
        k += 1
    }
    return true
}

/// Leftmost index `>= from` where `p[start..<start+len]` occurs in `s`.
@inline(__always) private func find(
    _ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ s: UnsafeBufferPointer<UInt8>, from: Int
) -> Int? {
    guard s.count - from >= len else { return nil }
    let first = p[start]
    var i = from
    let last = s.count - len
    while i <= last {
        if s[i] == first, equal(p, start, s, i, len) { return i }
        i += 1
    }
    return nil
}

// MARK: - Choosing the groups (§3.2)

/// `A-Z a-z _ -`: the characters of a product token.
@inline(__always) private func isTokenByte(_ b: UInt8) -> Bool {
    switch b {
    case 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: true
    default: false
    }
}

@inline(__always) private func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }

private enum GroupToken {
    case global
    case name(ArraySlice<UInt8>)

    /// D-001: `*` alone or followed by a space or tab is global; otherwise the
    /// value's longest `[A-Za-z_-]` prefix (possibly empty, which matches nothing).
    init(_ value: String) {
        let u = Array(value.utf8)
        if u.first == star, u.count == 1 || u[1] == 0x20 || u[1] == 0x09 {
            self = .global
        } else {
            self = .name(u.prefix(while: isTokenByte))
        }
    }
}

/// D-003: the crawler's user agent must be a product token, `[A-Za-z_-]+`.
private func validUserAgent(_ userAgent: String) throws(RobotsError) -> [UInt8] {
    let u = Array(userAgent.utf8)
    guard !u.isEmpty, u.allSatisfy(isTokenByte) else { throw .invalidUserAgent }
    return u
}

/// The crawler's groups in file order: every group naming its token (ASCII case
/// ignored), or, only if there are none, the global groups (D-002).
private func groups(for agent: [UInt8], in robots: RobotsFile) -> [Group] {
    var own: [Group] = [], global: [Group] = []
    for g in robots.groups {
        var named = false, isGlobal = false
        for ua in g.userAgents {
            switch GroupToken(ua) {
            case .global:
                isGlobal = true
            case .name(let t):
                if t.count == agent.count, zip(t, agent).allSatisfy({ lower($0) == lower($1) }) { named = true }
            }
        }
        if named { own.append(g) } else if isGlobal { global.append(g) }
    }
    return own.isEmpty ? global : own
}

// MARK: - Operations

/// Spec operation `matching_rule`: the rule that decides `isAllowed`, or nil when no
/// rule matches (and always for `/robots.txt`).
///
/// - Parameters:
///   - userAgent: the crawler's product token, `[A-Za-z_-]+` (not a full User-Agent header).
///   - path: starts with `/` and includes the query; anything from `#` is ignored.
/// - Throws: `robotstxt.invalid_user_agent`, then `robotstxt.invalid_path`, checked in that order.
public func matchingRule(_ robots: RobotsFile, userAgent: String, path: String) throws(RobotsError) -> Rule? {
    let agent = try validUserAgent(userAgent)
    var p = Array(path.utf8)
    guard p.first == 0x2F else { throw .invalidPath }
    if let fragment = p.firstIndex(of: 0x23) { p.removeSubrange(fragment...) }

    // RFC 9309 §2.2.2: /robots.txt is always allowed.
    if p.prefix(while: { $0 != 0x3F }).elementsEqual("/robots.txt".utf8) { return nil }

    let normalizedPath = normalize(p)
    var best: Rule?
    for group in groups(for: agent, in: robots) {
        for rule in group.rules where matches(pattern: rule.normalized, path: normalizedPath) {
            guard let b = best else { best = rule; continue }
            // Longest pattern wins; on a tie allow beats disallow; else the first in the file.
            if rule.normalized.count > b.normalized.count
                || (rule.normalized.count == b.normalized.count && rule.allow && !b.allow) {
                best = rule
            }
        }
    }
    return best
}

/// Spec operation `is_allowed`: whether the crawler may fetch the path. True when no
/// rule matches or the deciding rule is `allow`.
///
/// - Throws: `robotstxt.invalid_user_agent`, then `robotstxt.invalid_path`, checked in that order.
public func isAllowed(_ robots: RobotsFile, userAgent: String, path: String) throws(RobotsError) -> Bool {
    try matchingRule(robots, userAgent: userAgent, path: path)?.allow ?? true
}

/// Spec operation `crawl_delay` (extension, not RFC 9309): the `Crawl-delay` that
/// applies to the crawler, in seconds: the first of its groups (§3.2) that has one.
///
/// - Throws: `robotstxt.invalid_user_agent`.
public func crawlDelay(_ robots: RobotsFile, userAgent: String) throws(RobotsError) -> Double? {
    let agent = try validUserAgent(userAgent)
    return groups(for: agent, in: robots).lazy.compactMap(\.crawlDelay).first
}

/// Spec operation `status_policy`: what the HTTP status of a `/robots.txt` fetch means.
public func statusPolicy(_ httpStatus: UInt32) -> StatusPolicy {
    switch httpStatus {
    case 200...299: .parse
    case 300...399: .followRedirect
    case 429: .disallowAll  // rate limited: unreachable (D-008)
    case 400...499: .allowAll
    default: .disallowAll  // 5xx, and anything that isn't a final status (D-008)
    }
}
