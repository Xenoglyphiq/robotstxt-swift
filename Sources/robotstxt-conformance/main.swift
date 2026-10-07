// Conformance runner: every case in `.spec/conformance/manifest.json`, compared the way
// the case says (`exact`, `float_tol`, `json_equal`).
// Usage: swift run robotstxt-conformance [manifest.json]   (exit 0 only if all pass)

import Foundation
import RobotsTxt

/// Canonical JSON (`.kit/CONVENTIONS.md` §5). Decoded with JSONDecoder, which keeps
/// booleans and numbers apart identically on Apple platforms and Linux.
indirect enum JSON: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? { if case .object(let o) = self { o[key] } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }

    /// A u64 in canonical form: a number up to 2^53, or a decimal string beyond.
    var u64: UInt64? {
        switch self {
        case .number(let n): UInt64(exactly: n)
        case .string(let s): UInt64(s)
        default: nil
        }
    }

    func matches(_ other: JSON, tol: Double) -> Bool {
        switch (self, other) {
        case let (.number(a), .number(b)): abs(a - b) <= tol
        case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { $0.matches($1, tol: tol) }
        case let (.object(a), .object(b)): Set(a.keys) == Set(b.keys) && a.allSatisfy { $0.value.matches(b[$0.key]!, tol: tol) }
        default: self == other
        }
    }

    var text: String {
        switch self {
        case .null: "null"
        case .bool(let b): "\(b)"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? "\(Int64(n))" : "\(n)"
        case .string(let s): "\"\(s)\""
        case .array(let a): "[" + a.map(\.text).joined(separator: ",") + "]"
        case .object(let o): "{" + o.keys.sorted().map { "\"\($0)\":\(o[$0]!.text)" }.joined(separator: ",") + "}"
        }
    }
}

let manifestPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".spec/conformance/manifest.json"
guard let data = FileManager.default.contents(atPath: manifestPath),
      let manifest = try? JSONDecoder().decode(JSON.self, from: data),
      let cases = manifest["cases"]?.array else {
    FileHandle.standardError.write(Data("cannot read \(manifestPath)\n".utf8))
    exit(2)
}

// MARK: values to canonical JSON

func ruleJSON(_ r: Rule) -> JSON {
    .object(["allow": .bool(r.allow), "pattern": .string(r.pattern), "line": .number(Double(r.line))])
}

func robotsJSON(_ f: RobotsFile) -> JSON {
    .object([
        "groups": .array(f.groups.map { g in
            .object([
                "user_agents": .array(g.userAgents.map(JSON.string)),
                "rules": .array(g.rules.map(ruleJSON)),
                "crawl_delay": g.crawlDelay.map(JSON.number) ?? .null,
            ])
        }),
        "sitemaps": .array(f.sitemaps.map(JSON.string)),
        "truncated": .bool(f.truncated),
    ])
}

/// A robots.txt file: `input.value` (text) or `input.base64` (raw bytes).
func inputBytes(_ input: JSON) -> [UInt8] {
    if let b = input["base64"]?.string { return [UInt8](Data(base64Encoded: b)!) }
    return Array((input["value"]?.string ?? "").utf8)
}

func limits(_ options: JSON?) -> Limits {
    var l = Limits()
    if let v = options?["max_bytes"]?.u64 { l.maxBytes = v }
    if let v = options?["max_redirects"]?.u64 { l.maxRedirects = UInt32(v) }
    return l
}

// MARK: run

func run(_ c: JSON) async -> Result<JSON, RobotsError> {
    let input = c["input"]!
    let opts = limits(c["options"])
    let args = input["args"]
    do throws(RobotsError) {
        switch c["op"]!.string! {
        case "parse":
            return .success(robotsJSON(parse(inputBytes(input), limits: opts)))
        case "is_allowed":
            let robots = parse(inputBytes(input), limits: opts)
            return .success(.bool(try isAllowed(robots, userAgent: args!["user_agent"]!.string!, path: args!["path"]!.string!)))
        case "matching_rule":
            let robots = parse(inputBytes(input), limits: opts)
            let rule = try matchingRule(robots, userAgent: args!["user_agent"]!.string!, path: args!["path"]!.string!)
            return .success(rule.map(ruleJSON) ?? .null)
        case "crawl_delay":
            let robots = parse(inputBytes(input), limits: opts)
            return .success(try crawlDelay(robots, userAgent: args!["user_agent"]!.string!).map(JSON.number) ?? .null)
        case "status_policy":
            return .success(.string(statusPolicy(UInt32(input["value"]!.u64!)).rawValue))
        default:
            return .failure(RobotsError(.internal, "runner.unknown_op"))
        }
    } catch {
        return .failure(error)
    }
}

var passed = [String: Int](), totals = [String: Int]()
for c in cases {
    let id = c["id"]!.string!, level = c["level"]!.string!
    totals[level, default: 0] += 1
    let expect = c["expect"]!
    let tol = c["tolerance"]?.number ?? 0
    var why: String?
    switch await run(c) {
    case .failure(let e):
        if let want = expect["error"] {
            if want["kind"]?.string != e.kind.rawValue || want["code"]?.string != e.code {
                why = "expected \(want["kind"]!.text)/\(want["code"]!.text), got \(e.kind.rawValue)/\(e.code)"
            }
        } else {
            why = "unexpected error \(e.code) (\(e.kind.rawValue))"
        }
    case .success(let got):
        if expect["error"] != nil {
            why = "expected an error, got \(got.text)"
        } else {
            let want = expect["value"] ?? .null
            if !got.matches(want, tol: tol) { why = "expected \(want.text), got \(got.text)" }
        }
    }
    if let why { print("FAIL \(id): \(why)") } else { passed[level, default: 0] += 1 }
}

let core = (passed["core"] ?? 0, totals["core"] ?? 0), io = (passed["io"] ?? 0, totals["io"] ?? 0)
let full = (core.0 + io.0, core.1 + io.1)
print("robotstxt swift (spec \(manifest["spec_version"]?.string ?? "?")): core \(core.0)/\(core.1), io \(io.0)/\(io.1), full \(full.0)/\(full.1)")
exit(full.1 > 0 && full.0 == full.1 ? 0 : 1)
