// Mutation fuzzer for everything that takes untrusted input: parse, and isAllowed /
// matchingRule / crawlDelay on the parsed result with mutated user agents and paths.
// Shared design: corpus = the conformance inputs; 1-4 random mutations per iteration;
// time-boxed.
//
//   FUZZ_SECONDS=600 swift run -c release robotstxt-fuzz
//   FUZZ_SEED=<n> reproduces a run; FUZZ_TRACE=<path> writes each input before running it,
//   so after a crash the file holds the input that caused it.
//
// Optimized Swift builds keep overflow and bounds checks, so a missing guard traps.
// `parse` can't throw (its signature has no `throws`). Invariants beyond "no trap":
// - only the declared errors, exactly when the spec says, user agent before path;
// - isAllowed == (matchingRule == nil || rule.allow), and the rule is one of the file's;
// - truncated iff the input is longer than maxBytes; rule lines increase through the file;
// - crawlDelay is nil or a non-negative number.

import Foundation
import RobotsTxt

let seconds = Double(ProcessInfo.processInfo.environment["FUZZ_SECONDS"] ?? "10") ?? 10
let seed = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970 * 1000)
let tracePath = ProcessInfo.processInfo.environment["FUZZ_TRACE"]
/// Unbuffered, so the seed is on screen even if a failed invariant traps the process.
func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
say("fuzz: seed \(seed), \(seconds) s")

/// SplitMix64: small, fast, reproducible.
struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}
var rng = Rng(state: seed)

// MARK: corpus

/// Minimal reader for the manifest: every robots.txt input (text or base64).
struct Manifest: Decodable {
    struct Case: Decodable {
        struct Input: Decodable {
            let value: Value?
            let base64: String?
        }
        let op: String
        let input: Input
    }
    enum Value: Decodable {
        case text(String), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            self = (try? c.decode(String.self)).map(Value.text) ?? .other
        }
    }
    let cases: [Case]
}

guard let data = FileManager.default.contents(atPath: ".spec/conformance/manifest.json"),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
    fatalError("run from the repo root: .spec/conformance/manifest.json not found")
}
let corpus: [[UInt8]] = {
    var corpus: [[UInt8]] = []
    for c in manifest.cases {
        if case .text(let s)? = c.input.value { corpus.append(Array(s.utf8)) }
        if let b = c.input.base64, let d = Data(base64Encoded: b) { corpus.append([UInt8](d)) }
    }
    // Seeds aimed at the matcher: many `*`, `$` in odd places, percent escapes.
    corpus.append(Array(("User-agent: *\nDisallow: /" + String(repeating: "*a", count: 40) + "*b$\n").utf8))
    corpus.append(Array("User-agent: FooBot\nAllow: /%7e%2F%e3%83%84*$x$\nDisallow: /*%*%%41\n".utf8))
    return corpus
}()
precondition(corpus.count > 50, "corpus not loaded")

/// Fragments that mean something to the parser, inserted by the mutator.
let tokens: [[UInt8]] = [
    "user-agent:", "User-Agent: FooBot", "user-agent *", "allow:", "disallow:", "Disallow /", "crawl-delay: 1.5",
    "sitemap:", ":", "*", "$", "#", "%", "%7E", "%2f", "%e3%83%84", "\r", "\n", "\r\n", " ", "\t", "/", "?",
    "\u{FEFF}", "ツ", "FooBot/2.1",
].map { Array($0.utf8) }

func mutate(_ input: [UInt8], _ rng: inout Rng) -> [UInt8] {
    var s = input
    for _ in 0...rng.below(4) {
        switch rng.below(8) {
        case 0 where !s.isEmpty: s[rng.below(s.count)] ^= UInt8(1 + rng.below(255))
        case 1: s.insert(rng.below(2) == 0 ? UInt8(rng.below(128)) : UInt8(rng.below(256)), at: rng.below(s.count + 1))
        case 2 where !s.isEmpty: s.remove(at: rng.below(s.count))
        case 3 where !s.isEmpty:
            let a = rng.below(s.count), b = min(s.count, a + 1 + rng.below(64))
            s.insert(contentsOf: s[a..<b], at: rng.below(s.count + 1))
        case 4 where !s.isEmpty: s.removeLast(rng.below(s.count))
        case 5, 6: s.insert(contentsOf: tokens[rng.below(tokens.count)], at: rng.below(s.count + 1))
        default: s.append(contentsOf: corpus[rng.below(corpus.count)])
        }
        if s.count > 100_000 { s.removeLast(s.count - 100_000) }
    }
    return s
}

// MARK: oracle-free checks

let tokenBytes = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-".utf8))
func validAgent(_ s: String) -> Bool { !s.utf8.isEmpty && s.utf8.allSatisfy(tokenBytes.contains) }

let agents = ["FooBot", "foobot", "BarBot", "a", "b", "c", "*", "", "Foo Bar", "FooBot/2.1", "ツ", "-_-"]
func pickAgent(_ robots: RobotsFile, _ rng: inout Rng) -> String {
    switch rng.below(3) {
    case 0 where !robots.groups.isEmpty:
        let g = robots.groups[rng.below(robots.groups.count)]
        let ua = g.userAgents[rng.below(g.userAgents.count)]
        return rng.below(4) == 0 ? ua : String(ua.prefix(while: { $0.isLetter && $0.isASCII || $0 == "_" || $0 == "-" }))
    case 1: return String(decoding: mutate(Array(agents[rng.below(agents.count)].utf8), &rng).prefix(12), as: UTF8.self)
    default: return agents[rng.below(agents.count)]
    }
}

func pickPath(_ robots: RobotsFile, _ rng: inout Rng) -> String {
    let rules = robots.groups.flatMap(\.rules)
    var p: [UInt8]
    if !rules.isEmpty, rng.below(3) > 0 {
        // A rule's pattern with each `*` replaced by a few random bytes and `$` dropped.
        p = []
        for b in rules[rng.below(rules.count)].pattern.utf8 {
            if b == 0x2A { for _ in 0..<rng.below(4) { p.append(UInt8(0x21 + rng.below(94))) } }
            else if b != 0x24 || rng.below(2) == 0 { p.append(b) }
        }
    } else {
        p = Array(["/", "/robots.txt", "/robots.txt?x", "/a#b", "/x/page.html", "/%7Euser", "/ツ"][rng.below(7)].utf8)
    }
    if rng.below(2) == 0 { p = mutate(p, &rng) }
    if p.count > 4096 { p.removeLast(p.count - 4096) }
    return String(decoding: p, as: UTF8.self)
}

let deadline = Date().addingTimeInterval(seconds)
var iterations = 0
while Date() < deadline {
    for _ in 0..<256 {
        let input = mutate(corpus[rng.below(corpus.count)], &rng)
        if let tracePath { FileManager.default.createFile(atPath: tracePath, contents: Data(input)) }
        iterations += 1

        let limits = rng.below(4) == 0 ? Limits(maxBytes: UInt64(rng.below(input.count + 2))) : Limits()
        let robots = parse(input, limits: limits)
        precondition(robots.truncated == (UInt64(input.count) > limits.maxBytes), "truncated flag wrong")
        precondition(robots.groups.allSatisfy { !$0.userAgents.isEmpty }, "group without a user agent")
        let lines = robots.groups.flatMap(\.rules).map(\.line)
        precondition(zip(lines, lines.dropFirst()).allSatisfy { $0 < $1 }, "rule lines not increasing")
        precondition(robots.groups.allSatisfy { g in g.rules.allSatisfy { !$0.pattern.isEmpty } }, "empty rule")

        for _ in 0..<4 {
            let ua = pickAgent(robots, &rng), path = pickPath(robots, &rng)
            let want: RobotsError? = !validAgent(ua) ? .invalidUserAgent : path.utf8.first != 0x2F ? .invalidPath : nil  // bytes: "/" + a combining mark is one Character
            let allowed: Result<Bool, RobotsError> = Result { () throws(RobotsError) in try isAllowed(robots, userAgent: ua, path: path) }
            let rule: Result<Rule?, RobotsError> = Result { () throws(RobotsError) in try matchingRule(robots, userAgent: ua, path: path) }
            switch (allowed, rule) {
            case let (.success(a), .success(r)):
                precondition(want == nil, "expected \(want!) for \(ua) \(path)")
                precondition(a == (r == nil || r!.allow), "isAllowed disagrees with matchingRule")
                if let r { precondition(robots.groups.contains { $0.rules.contains(r) }, "rule not in the file") }
            case let (.failure(e1), .failure(e2)):
                precondition(e1 == e2 && e1 == want, "wrong error \(e1) / \(e2), expected \(String(describing: want))")
            default:
                preconditionFailure("isAllowed and matchingRule disagree on failing")
            }
            switch Result(catching: { () throws(RobotsError) in try crawlDelay(robots, userAgent: ua) }) {
            case .success(let d):
                precondition(validAgent(ua), "crawlDelay accepted \(ua)")
                if let d { precondition(d >= 0, "negative crawl delay") }
            case .failure(let e):
                precondition(e == .invalidUserAgent && !validAgent(ua), "crawlDelay threw \(e)")
            }
        }
        _ = statusPolicy(UInt32(truncatingIfNeeded: rng.next()))
    }
}
say("fuzz: \(iterations) iterations in \(seconds) s, clean")
