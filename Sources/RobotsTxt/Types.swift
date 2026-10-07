// Types from the robotstxt spec (`.spec/spec/capability.yaml`). Core never imports Foundation.

/// Error raised by the robots.txt operations. `kind` and `code` are the spec's
/// stable error kind and code (e.g. `robotstxt.invalid_path`); tests and callers
/// should match on those, never on message text.
public struct RobotsError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case invalidInput = "invalid_input"
        case unsupported
        case limitExceeded = "limit_exceeded"
        case notFound = "not_found"
        case io
        case `internal`
    }

    public let kind: Kind
    public let code: String

    public init(_ kind: Kind, _ code: String) {
        self.kind = kind
        self.code = code
    }

    /// The user agent is empty or has characters outside `[A-Za-z_-]`.
    public static let invalidUserAgent = RobotsError(.invalidInput, "robotstxt.invalid_user_agent")
    /// The path doesn't start with `/`.
    public static let invalidPath = RobotsError(.invalidInput, "robotstxt.invalid_path")
    /// Not an http or https origin (scheme and authority only). Raised by `fetch` (io).
    public static let invalidOrigin = RobotsError(.invalidInput, "robotstxt.invalid_origin")

    public var description: String { "\(code) (\(kind.rawValue))" }
}

/// Limits on untrusted input. Defaults match the spec (§5).
public struct Limits: Sendable, Hashable {
    /// Bytes of a robots.txt file that are parsed; the rest is ignored and
    /// `RobotsFile.truncated` is set. RFC 9309 §2.5 requires at least 500 KiB.
    public var maxBytes: UInt64 = 512_000
    /// Redirects `fetch` follows before treating the file as unavailable (RFC 9309 §2.3.1.2).
    public var maxRedirects: UInt32 = 5

    public init(maxBytes: UInt64 = 512_000, maxRedirects: UInt32 = 5) {
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
    }
}

/// One `allow` or `disallow` line.
public struct Rule: Sendable, Hashable {
    public let allow: Bool
    /// The pattern as written, trimmed; not normalized. Bytes that aren't valid
    /// UTF-8 are reported as U+FFFD, but matching uses the original bytes.
    public let pattern: String
    /// 1-based line number in the file.
    public let line: UInt32

    /// The original pattern bytes, normalized (spec §3.3 step 2). Matching uses these.
    let normalized: [UInt8]

    public init(allow: Bool, pattern: String, line: UInt32) {
        self.init(allow: allow, raw: Array(pattern.utf8)[...], line: line)
    }

    init(allow: Bool, raw: ArraySlice<UInt8>, line: UInt32) {
        self.allow = allow
        self.pattern = String(decoding: raw, as: UTF8.self)
        self.line = line
        self.normalized = normalize(raw)
    }
}

/// One or more `user-agent` lines and the group members that follow them.
public struct Group: Sendable, Hashable {
    /// The `user-agent` values as written, trimmed.
    public var userAgents: [String]
    public var rules: [Rule]
    /// Extension, not RFC 9309: the group's first valid `Crawl-delay`, in seconds.
    public var crawlDelay: Double?

    public init(userAgents: [String], rules: [Rule] = [], crawlDelay: Double? = nil) {
        self.userAgents = userAgents
        self.rules = rules
        self.crawlDelay = crawlDelay
    }
}

/// A parsed robots.txt file.
public struct RobotsFile: Sendable, Hashable {
    /// Groups in file order. Groups naming the same agent are not merged here;
    /// they're merged when matching (spec §3.2).
    public var groups: [Group]
    /// `Sitemap` URLs in file order.
    public var sitemaps: [String]
    /// The input was longer than `Limits.maxBytes`.
    public var truncated: Bool

    public init(groups: [Group] = [], sitemaps: [String] = [], truncated: Bool = false) {
        self.groups = groups
        self.sitemaps = sitemaps
        self.truncated = truncated
    }
}

/// What an HTTP status for `/robots.txt` means (spec §3.5, RFC 9309 §2.3.1).
public enum StatusPolicy: String, Sendable, Hashable {
    /// 2xx: parse the body.
    case parse
    /// 3xx: follow the redirect.
    case followRedirect = "follow_redirect"
    /// "Unavailable" (4xx except 429): crawlers may access anything.
    case allowAll = "allow_all"
    /// "Unreachable" (429, 5xx, anything else): crawlers may access nothing.
    case disallowAll = "disallow_all"
}
