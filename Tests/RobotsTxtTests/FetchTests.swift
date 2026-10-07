import Foundation
import Testing
@testable import RobotsTxtIO

/// Answers from a map and records every request.
private final class Scripted: Transport, @unchecked Sendable {
    let responses: [String: TransportResponse]
    private let lock = NSLock()
    private(set) var requests: [(String, Int)] = []

    init(_ responses: [String: TransportResponse]) { self.responses = responses }

    func get(_ url: URL, maxBodyBytes: Int) async -> TransportResponse? {
        record(url.absoluteString, maxBodyBytes)
        return responses[url.absoluteString]
    }

    private func record(_ url: String, _ maxBodyBytes: Int) {
        lock.lock(); requests.append((url, maxBodyBytes)); lock.unlock()
    }
}

@Test(arguments: [
    "http://example.com", "https://example.com/", "https://Example.com:8443", "http://127.0.0.1:8080/", "http://[::1]:80",
])
func validOrigins(origin: String) throws {
    #expect(try robotsURL(origin: origin).path == "/robots.txt")
}

@Test(arguments: [
    "", "example.com", "ftp://example.com", "https://", "https:///", "https://example.com//", "https://example.com/x",
    "https://example.com?a", "https://example.com#f", "https://user@example.com", "https://exa mple.com", "https://:80",
    "HTTPS://example.com", "Http://example.com",
])
func invalidOrigins(origin: String) async {
    await #expect(throws: RobotsError.invalidOrigin) { try await fetch(origin: origin, transport: Scripted([:])) }
}

@Test func redirectLoopStopsAfterTheLimit() async throws {
    let t = Scripted(["https://a.example/robots.txt": TransportResponse(status: 302, location: "/robots.txt")])
    let f = try await fetch(origin: "https://a.example", transport: t, limits: Limits(maxRedirects: 3))
    #expect(f == Fetched(policy: .allowAll, status: 302, robots: nil))
    #expect(t.requests.count == 4)  // the first request and three redirects
}

@Test func redirectToAnotherSchemeGetsNoResponse() async throws {
    let t = Scripted(["https://a.example/robots.txt": TransportResponse(status: 301, location: "file:///etc/hosts")])
    let f = try await fetch(origin: "https://a.example", transport: t)
    #expect(f == Fetched(policy: .disallowAll, status: nil, robots: nil))
    #expect(t.requests.count == 1)
}

@Test func emptyLocationIsMissing() async throws {
    let t = Scripted(["https://a.example/robots.txt": TransportResponse(status: 302, location: " ")])
    #expect(try await fetch(origin: "https://a.example", transport: t) == Fetched(policy: .allowAll, status: 302, robots: nil))
}

@Test(arguments: [
    ("/r/./x/../robots.txt", "https://a.example/r/robots.txt"), ("../../x/./robots.txt", "https://a.example/x/robots.txt"),
    ("https://b.example/a/../robots.txt#frag", "https://b.example/robots.txt"), ("/r?x#y", "https://a.example/r?x"),
    ("HTTP://b.example/robots.txt", "http://b.example/robots.txt"), ("//c.example/./robots.txt", "https://c.example/robots.txt"),
])
func locationsResolvePerRFC3986(location: String, want: String) async throws {
    let t = Scripted(["https://a.example/robots.txt": TransportResponse(status: 301, location: location)])
    _ = try await fetch(origin: "https://a.example", transport: t)
    #expect(t.requests.map(\.0) == ["https://a.example/robots.txt", want])
}

@Test func bodyLimitIsPassedAndApplied() async throws {
    let body = Array("User-agent: *\nDisallow: /a\nDisallow: /b\n".utf8)
    let t = Scripted(["http://a.example/robots.txt": TransportResponse(status: 200, body: body)])
    let f = try await fetch(origin: "http://a.example", transport: t, limits: Limits(maxBytes: 30))
    #expect(t.requests.first?.1 == 31)
    #expect(f.robots?.truncated == true && f.robots?.groups.first?.rules.count == 1)
}

@Test func policyDecidesEveryPath() async throws {
    let t = Scripted(["http://a.example/robots.txt": TransportResponse(status: 503)])
    let f = try await fetch(origin: "http://a.example", transport: t)
    #expect(try !f.isAllowed(userAgent: "FooBot", path: "/"))
    let missing = try await fetch(origin: "http://b.example", transport: t)  // no response at all
    #expect(missing == Fetched(policy: .disallowAll, status: nil, robots: nil))
    #expect(try Fetched(policy: .allowAll, status: 404, robots: nil).isAllowed(userAgent: "FooBot", path: "/x"))
    #expect(throws: RobotsError.invalidUserAgent) { try f.isAllowed(userAgent: "Foo Bot", path: "/") }
}
