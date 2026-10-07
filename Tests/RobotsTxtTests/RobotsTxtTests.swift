import Testing
@testable import RobotsTxt

private func allowed(_ file: String, _ agent: String = "FooBot", path: String) throws -> Bool {
    try isAllowed(parse(file), userAgent: agent, path: path)
}

// MARK: - Matcher

@Test(arguments: [
    ("/", "/", true), ("/a", "/", false), ("/a*", "/a", true), ("/a*b", "/axxb", true), ("/a*b", "/axx", false),
    ("/a*b$", "/axbxb", true), ("/a*b$", "/axbx", false), ("*", "/anything", true), ("*$", "/x", true),
    ("$", "/", false), ("/a$", "/a", true), ("/a$", "/ab", false), ("/a$b", "/a$b", true), ("/a$b", "/ab", false),
    ("/*.php", "/index.php?x", true), ("/*.php$", "/index.php?x", false), ("/**/x", "/a/b/x", true),
    ("/a*a*a", "/aa", false), ("/a*a*a", "/aaa", true), ("/x*", "/", false),
])
func matcherCases(pattern: String, path: String, want: Bool) {
    #expect(matches(pattern: normalize(pattern.utf8), path: normalize(path.utf8)) == want)
}

@Test func manyStarsStayFast() {
    // A backtracking matcher takes exponential time on this; the greedy one is linear per piece.
    let pattern = "/" + String(repeating: "*a", count: 200) + "*b"
    let path = "/" + String(repeating: "a", count: 50_000)
    let clock = ContinuousClock()
    var result = true
    let elapsed = clock.measure {
        result = matches(pattern: normalize(pattern.utf8), path: normalize(path.utf8))
        result = result || matches(pattern: normalize((pattern + "$").utf8), path: normalize(path.utf8))
    }
    #expect(result == false)
    #expect(elapsed < .seconds(2))
    // And the anchored case that does match: the last piece sits at the very end.
    #expect(matches(pattern: normalize(("/" + String(repeating: "*a", count: 200) + "$").utf8),
                    path: normalize(("/" + String(repeating: "a", count: 300)).utf8)))
}

@Test func longestMatchThenAllowThenFirst() throws {
    let file = "user-agent: FooBot\ndisallow: /a\nallow: /a\ndisallow: /*b\nallow: /ab\n"
    let robots = parse(file)
    // /ab: "/*b" and "/ab" are both 3 bytes; allow wins the tie.
    #expect(try matchingRule(robots, userAgent: "FooBot", path: "/ab")?.line == 5)
    // /a: "/a" twice, allow wins.
    #expect(try matchingRule(robots, userAgent: "FooBot", path: "/a")?.line == 3)
    // Same kind and length: first in file.
    #expect(try matchingRule(parse("user-agent: x\ndisallow: /*a\ndisallow: /a*\n"), userAgent: "x", path: "/a")?.line == 2)
}

// MARK: - Normalization

@Test(arguments: [
    ("/%7Euser", "/~user"), ("/%7e", "/~"), ("/%2f", "/%2F"), ("/%2F", "/%2F"), ("/ツ", "/%E3%83%84"),
    ("/%e3%83%84", "/%E3%83%84"), ("/a b", "/a%20b"), ("/\t\u{7F}", "/%09%7F"), ("/%", "/%"), ("/%4", "/%4"),
    ("/%zz", "/%zz"), ("/%41%5a%30%2D%2E%5F", "/AZ0-._"), ("/?a=1&b=/", "/?a=1&b=/"), ("/%25", "/%25"), ("/%2A", "/%2A"),
])
func normalization(input: String, want: String) {
    #expect(normalize(input.utf8) == Array(want.utf8))
}

@Test func normalizationAppliesToBothSides() throws {
    #expect(try !allowed("user-agent: *\ndisallow: /%7Euser\n", path: "/~user"))
    #expect(try !allowed("user-agent: *\ndisallow: /~user\n", path: "/%7euser"))
    #expect(try !allowed("user-agent: *\ndisallow: /ツ\n", path: "/%E3%83%84"))
    #expect(try allowed("user-agent: *\ndisallow: /a%2Fb\n", path: "/a/b"))
    // `%2A` and `%24` are literal bytes, never wildcards.
    #expect(try allowed("user-agent: *\ndisallow: /a%2Ab\n", path: "/axb"))
    #expect(try !allowed("user-agent: *\ndisallow: /a%2Ab\n", path: "/a%2ab"))
}

@Test func invalidUTF8MatchesOnBytes() throws {
    // Pattern byte E9 is reported as U+FFFD but matched as %E9.
    let robots = parse([UInt8]("user-agent: *\ndisallow: /caf".utf8) + [0xE9])
    #expect(robots.groups[0].rules[0].pattern == "/caf\u{FFFD}")
    #expect(try !isAllowed(robots, userAgent: "x", path: "/caf%E9"))
    #expect(try isAllowed(robots, userAgent: "x", path: "/caf\u{FFFD}"))
}

// MARK: - Truncation (D-005)

private let file = Array("User-agent: *\r\nDisallow: /a\r\nDisallow: /b\r\n".utf8)  // 15 + 14 + 14 = 43 bytes

@Test(arguments: [
    (43, ["/a", "/b"], false), (42, ["/a", "/b"], true), (41, ["/a"], true), (40, ["/a"], true),
    (29, ["/a"], true), (28, ["/a"], true), (27, [], true), (15, [], true), (14, [], true), (13, [], true), (0, [], true),
])
func truncationBoundary(maxBytes: Int, patterns: [String], truncated: Bool) {
    let robots = parse(file, limits: Limits(maxBytes: UInt64(maxBytes)))
    #expect(robots.truncated == truncated)
    #expect(robots.groups.flatMap(\.rules).map(\.pattern) == patterns)
    // 14 bytes still hold the whole first line (it ends at its `\r`); 13 cut it.
    #expect(robots.groups.isEmpty == (maxBytes <= 13))
}

@Test func cutBetweenCRAndLFKeepsTheLine() {
    // 42 bytes end with the last line's `\r`: the line is complete, only its `\n` is cut.
    let robots = parse(file, limits: Limits(maxBytes: 42))
    #expect(robots.truncated)
    #expect(robots.groups[0].rules.map(\.line) == [2, 3])
}

@Test func truncationNeverReadsPastTheLimit() {
    let big = Array(String(repeating: "Disallow: /x\n", count: 50_000).utf8)  // 650,000 bytes
    let robots = parse(Array("User-agent: *\n".utf8) + big)
    #expect(robots.truncated)
    #expect(robots.groups[0].rules.allSatisfy { $0.pattern == "/x" })
    #expect(robots.groups[0].rules.last!.line <= 512_000 / 13 + 1)
}

// MARK: - Parsing details

@Test func lineEndingsAndNumbers() {
    let robots = parse("User-agent: a\r\rDisallow: /x\r\n\nAllow: /y")
    #expect(robots.groups[0].rules.map(\.line) == [3, 5])
}

@Test func byteOrderMarkPrefixes() {
    for bom: [UInt8] in [[0xEF, 0xBB, 0xBF], [0xEF, 0xBB], [0xEF], []] {
        let robots = parse(bom + Array("User-agent: a\nDisallow: /\n".utf8))
        #expect(robots.groups.count == 1)
    }
    #expect(parse([0xBB, 0xBF] + Array("User-agent: a\nDisallow: /\n".utf8)).groups.isEmpty)
}

@Test func missingColonNeedsExactlyTwoWords() {
    #expect(parse("user-agent\tFooBot\ndisallow   /x\n").groups.first?.rules.map(\.pattern) == ["/x"])
    #expect(parse("user-agent FooBot\ndisallow /x y\n").groups.first?.rules.isEmpty == true)
    #expect(parse("user-agent\n").groups.isEmpty)
}

@Test func agentListOpensAndCloses() {
    // Unknown keys and sitemaps don't close the list; crawl-delay and empty disallow do.
    #expect(parse("user-agent: a\nfoo: bar\nsitemap: s\nuser-agent: b\n").groups.map(\.userAgents) == [["a", "b"]])
    #expect(parse("user-agent: a\ndisallow:\nuser-agent: b\n").groups.count == 2)
    #expect(parse("user-agent: a\ncrawl-delay: x\nuser-agent: b\n").groups.count == 2)
    // Rules and crawl-delay before any user-agent are ignored.
    #expect(parse("disallow: /\ncrawl-delay: 3\nuser-agent: a\n") == RobotsFile(groups: [Group(userAgents: ["a"])]))
}

@Test func crawlDelayValues() throws {
    let robots = parse("user-agent: a\ncrawl-delay: 1.\ncrawl-delay: .5\ncrawl-delay: 1e3\ncrawl-delay: 0.25\ncrawl-delay: 9\n")
    #expect(robots.groups[0].crawlDelay == 0.25)
    #expect(try crawlDelay(robots, userAgent: "A") == 0.25)
    #expect(try crawlDelay(robots, userAgent: "b") == nil)
}

// MARK: - Groups and arguments

@Test func groupTokens() throws {
    #expect(try !allowed("user-agent: FooBot/2.1\ndisallow: /\n", "foobot", path: "/"))
    #expect(try allowed("user-agent: foo\ndisallow: /\n", "foobar", path: "/"))
    #expect(try !allowed("user-agent: *\tx\ndisallow: /\n", path: "/"))
    #expect(try allowed("user-agent: *bot\ndisallow: /\n", path: "/"))
    // Own group with no matching rule: no fallback to `*` (D-002).
    #expect(try allowed("user-agent: FooBot\nallow: /p\n\nuser-agent: *\ndisallow: /\n", path: "/q"))
}

@Test func argumentsAreCheckedInOrder() {
    let robots = parse("user-agent: *\ndisallow: /\n")
    #expect(throws: RobotsError.invalidUserAgent) { try isAllowed(robots, userAgent: "Foo/1", path: "x") }
    #expect(throws: RobotsError.invalidPath) { try isAllowed(robots, userAgent: "Foo", path: "x") }
    #expect(throws: RobotsError.invalidPath) { try matchingRule(robots, userAgent: "Foo", path: "") }
    #expect(throws: RobotsError.invalidUserAgent) { try crawlDelay(robots, userAgent: "") }
    #expect(RobotsError.invalidPath.kind == .invalidInput && RobotsError.invalidPath.code == "robotstxt.invalid_path")
}

@Test func robotsTxtAndFragments() throws {
    let robots = parse("user-agent: *\ndisallow: /\nallow: /ok$\n")
    #expect(try isAllowed(robots, userAgent: "x", path: "/robots.txt"))
    #expect(try isAllowed(robots, userAgent: "x", path: "/robots.txt?x=1"))
    #expect(try matchingRule(robots, userAgent: "x", path: "/robots.txt#f") == nil)
    #expect(try !isAllowed(robots, userAgent: "x", path: "/robots.txt.bak"))
    #expect(try isAllowed(robots, userAgent: "x", path: "/ok#fragment"))
}

@Test func statusPolicies() {
    let table: [(UInt32, StatusPolicy)] = [
        (0, .disallowAll), (199, .disallowAll), (200, .parse), (299, .parse), (300, .followRedirect), (399, .followRedirect),
        (400, .allowAll), (428, .allowAll), (429, .disallowAll), (430, .allowAll), (499, .allowAll), (500, .disallowAll),
        (599, .disallowAll), (600, .disallowAll), (.max, .disallowAll),
    ]
    for (status, policy) in table { #expect(statusPolicy(status) == policy) }
}
