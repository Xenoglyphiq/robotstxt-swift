// io layer from the robotstxt spec §3.6: fetch `/robots.txt` for an origin, follow
// redirects, apply the status policy and parse. Format logic stays in RobotsTxt.

@_exported import RobotsTxt

#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#else
import Foundation
#endif

/// One HTTP response, as a `Transport` reports it.
public struct TransportResponse: Sendable, Hashable {
    /// The HTTP status code.
    public var status: UInt32
    /// The `Location` header, if any (used for redirects).
    public var location: String?
    /// The body. A transport may stop reading after the `maxBodyBytes` it was given.
    public var body: [UInt8]

    public init(status: UInt32, location: String? = nil, body: [UInt8] = []) {
        self.status = status
        self.location = location
        self.body = body
    }
}

/// Something that performs one HTTP GET without following redirects. `fetch` uses it,
/// so callers can supply their own client, and tests a scripted one.
public protocol Transport: Sendable {
    /// GETs `url` without following redirects. Returns nil when no response arrived
    /// (connection, TLS or timeout failure). Reading more than `maxBodyBytes` of the
    /// body isn't needed: `fetch` ignores the rest.
    func get(_ url: URL, maxBodyBytes: Int) async -> TransportResponse?
}

/// How `fetch` arrived at its result.
public enum FetchPolicy: String, Sendable, Hashable {
    /// A 2xx response, parsed.
    case parsed
    /// The file is unavailable (4xx except 429, too many redirects, or a redirect
    /// with nowhere to go): crawlers may access anything.
    case allowAll = "allow_all"
    /// The server is unreachable (no response, 429, 5xx, or no final status):
    /// crawlers may access nothing.
    case disallowAll = "disallow_all"
}

/// The result of `fetch`.
public struct Fetched: Sendable, Hashable {
    public var policy: FetchPolicy
    /// The final HTTP status; nil when there was no response.
    public var status: UInt32?
    /// The parsed file, present when `policy` is `.parsed`.
    public var robots: RobotsFile?

    public init(policy: FetchPolicy, status: UInt32?, robots: RobotsFile?) {
        self.policy = policy
        self.status = status
        self.robots = robots
    }

    /// Whether the crawler may fetch `path`, applying the policy: `allowAll` and
    /// `disallowAll` decide every path, `parsed` asks the file (`isAllowed`).
    /// The arguments are checked the same way in every case.
    ///
    /// - Throws: `robotstxt.invalid_user_agent`, then `robotstxt.invalid_path`.
    public func isAllowed(userAgent: String, path: String) throws(RobotsError) -> Bool {
        let fromFile = try RobotsTxt.isAllowed(robots ?? RobotsFile(), userAgent: userAgent, path: path)
        switch policy {
        case .parsed: return fromFile
        case .allowAll: return true
        case .disallowAll: return false
        }
    }
}

/// Spec operation `fetch`: requests `origin + /robots.txt`, follows up to
/// `limits.maxRedirects` redirects, applies `statusPolicy` and parses a 2xx body
/// (at most `limits.maxBytes + 1` bytes are read).
///
/// A failed fetch is a policy, not an error: no response is `.disallowAll`; too many
/// redirects, or a redirect without a usable `Location`, is `.allowAll` (D-007).
///
/// - Parameters:
///   - origin: `http://` or `https://` and an authority (host and optional port), with
///     at most a trailing `/`: no path, query or fragment.
///   - transport: performs each GET. The default is `URLSessionTransport.shared`.
/// - Throws: `robotstxt.invalid_origin`, the only error.
public func fetch(
    origin: String, transport: any Transport = URLSessionTransport.shared, limits: Limits = Limits()
) async throws(RobotsError) -> Fetched {
    var url = try robotsURL(origin: origin)
    let maxBody = Int(clamping: limits.maxBytes) &+ 1
    var redirects: UInt32 = 0
    while true {
        guard let response = await transport.get(url, maxBodyBytes: maxBody < 0 ? Int.max : maxBody) else {
            return Fetched(policy: .disallowAll, status: nil, robots: nil)
        }
        switch statusPolicy(response.status) {
        case .parse:
            return Fetched(policy: .parsed, status: response.status, robots: parse(response.body, limits: limits))
        case .followRedirect:
            guard redirects < limits.maxRedirects,
                  let location = response.location, let next = redirectTarget(location, from: url) else {
                return Fetched(policy: .allowAll, status: response.status, robots: nil)
            }
            redirects += 1
            url = next
        case .allowAll:
            return Fetched(policy: .allowAll, status: response.status, robots: nil)
        case .disallowAll:
            return Fetched(policy: .disallowAll, status: response.status, robots: nil)
        }
    }
}

/// `Location` resolved against the current URL. Only http and https targets are
/// followed; anything else is treated like a redirect with no `Location`.
private func redirectTarget(_ location: String, from current: URL) -> URL? {
    guard let next = URL(string: location, relativeTo: current)?.absoluteURL,
          let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = next.host, !host.isEmpty else { return nil }
    return next
}

/// `origin + /robots.txt`, after checking that `origin` is scheme and authority only.
func robotsURL(origin: String) throws(RobotsError) -> URL {
    let lower = origin.lowercased()
    let scheme: String
    if lower.hasPrefix("http://") { scheme = "http" } else if lower.hasPrefix("https://") { scheme = "https" } else {
        throw .invalidOrigin
    }
    var authority = origin.utf8.dropFirst(scheme.utf8.count + 3)
    if authority.last == UInt8(ascii: "/") { authority = authority.dropLast() }
    // Host and optional port only: no path, query, fragment, user info, spaces or controls.
    let forbidden = Set("/?#@\\".utf8)
    guard !authority.isEmpty, authority.allSatisfy({ $0 > 0x20 && $0 != 0x7F && !forbidden.contains($0) }) else {
        throw .invalidOrigin
    }
    guard let url = URL(string: "\(scheme)://\(String(decoding: authority, as: UTF8.self))/robots.txt"),
          let host = url.host, !host.isEmpty, url.path == "/robots.txt", url.query == nil else {
        throw .invalidOrigin
    }
    return url
}
