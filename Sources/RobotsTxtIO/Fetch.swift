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
/// A failed fetch is a policy, not an error: no response, or a redirect to a URL that
/// isn't http or https, is `.disallowAll` with no status; too many redirects, or a
/// redirect with a missing or empty `Location`, is `.allowAll` (D-007).
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
            guard redirects < limits.maxRedirects else {
                return Fetched(policy: .allowAll, status: response.status, robots: nil)
            }
            switch redirectTarget(response.location, from: url) {
            case .missing:
                return Fetched(policy: .allowAll, status: response.status, robots: nil)
            case .unrequestable:
                return Fetched(policy: .disallowAll, status: nil, robots: nil)
            case .url(let next):
                redirects += 1
                url = next
            }
        case .allowAll:
            return Fetched(policy: .allowAll, status: response.status, robots: nil)
        case .disallowAll:
            return Fetched(policy: .disallowAll, status: response.status, robots: nil)
        }
    }
}

private enum RedirectTarget {
    /// No `Location`, or an empty one: the file is unavailable (D-007).
    case missing
    /// A `Location` that isn't an http or https URL (or doesn't parse): nothing to
    /// request, so there's no response.
    case unrequestable
    case url(URL)
}

/// `Location` resolved against the current URL per RFC 3986 §5.2: dot segments
/// removed, the fragment dropped, the scheme lower-cased.
private func redirectTarget(_ location: String?, from current: URL) -> RedirectTarget {
    let trimmed = (location ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    if trimmed.isEmpty { return .missing }
    guard let resolved = URL(string: trimmed, relativeTo: current)?.absoluteURL.standardized,
          var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
          let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = parts.host, !host.isEmpty else { return .unrequestable }
    parts.scheme = scheme
    parts.fragment = nil
    guard let next = parts.url else { return .unrequestable }
    return .url(next)
}

/// `origin + /robots.txt`, after checking that `origin` is scheme and authority only.
func robotsURL(origin: String) throws(RobotsError) -> URL {
    // Lower-case schemes only, as every port of the spec does.
    let scheme: String
    if origin.hasPrefix("http://") { scheme = "http" } else if origin.hasPrefix("https://") { scheme = "https" } else {
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
