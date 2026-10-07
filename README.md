# robots.txt for Swift

Parse robots.txt files and decide whether a crawler may fetch a path: which rule decided, sitemap URLs, what an HTTP status means for the file, and fetching it over HTTP. Implements [RFC 9309](https://www.rfc-editor.org/rfc/rfc9309.html) · Spec v0.1.0 · Conformance: **core ✓ io ✓ full ✓** (125/125)

Swift tools 6.0 · iOS 16 / macOS 13 / Linux. **No dependencies.** The core works on UTF-8 bytes with a hand-written matcher (no `Regex`, no Foundation), so it behaves the same on every platform.

## Install

> **Not released yet.** Until the first release, depend on `main`:
> `.package(url: "https://github.com/Xenoglyphiq/robotstxt-swift", branch: "main")`

Then add `RobotsTxt` (core) and/or `RobotsTxtIO` (`fetch`) to your target.

## Quick start

```swift
import RobotsTxt

let robots = parse("""
    User-agent: *
    Disallow: /private/
    Allow: /private/press/
    """)
try isAllowed(robots, userAgent: "FooBot", path: "/private/page")        // false
try matchingRule(robots, userAgent: "FooBot", path: "/private/press/1")  // allow /private/press/ (line 3)
```

The user agent is the crawler's **product token** (`FooBot`, `[A-Za-z_-]+`), not a full `User-Agent` header. The path starts with `/` and includes the query; URL parsing is up to you.

To fetch a site's file and apply the HTTP status rules:

```swift
import RobotsTxtIO

let fetched = try await fetch(origin: "https://example.com")
try fetched.isAllowed(userAgent: "FooBot", path: "/private/page")
```

## Examples

Each runs with `swift run <name>` and embeds a sample robots.txt.

### 1. Check one path (`Examples/check_path`)
```swift
let allowed = try isAllowed(parse(sample), userAgent: "NowhereToBeBot", path: "/private/page")
```
```
NowhereToBeBot may not fetch /private/page
```

### 2. List the sitemaps (`Examples/list_sitemaps`)
```swift
for url in parse(sample).sitemaps { print(url) }
```

### 3. Explain a decision (`Examples/explain_decision`)
```swift
if let rule = try matchingRule(parse(sample), userAgent: agent, path: path) {
    print("\(rule.allow ? "allow" : "disallow") \(rule.pattern) (line \(rule.line))")
} else {
    print("no rule applies")
}
```
```
NowhereToBeBot /private/press/2026.html: allow /private/press/ (line 7)
```

## API

| Function | Spec operation | Product |
|---|---|---|
| `parse(_:limits:)` (bytes or `String`) → `RobotsFile` | `parse` (§3.1). Never fails | `RobotsTxt` |
| `isAllowed(_:userAgent:path:)` → `Bool` | `is_allowed` (§3.3) | `RobotsTxt` |
| `matchingRule(_:userAgent:path:)` → `Rule?` | `matching_rule` (§3.3) | `RobotsTxt` |
| `crawlDelay(_:userAgent:)` → `Double?` | `crawl_delay` (§3.4). **Extension, not RFC 9309** | `RobotsTxt` |
| `statusPolicy(_:)` → `StatusPolicy` | `status_policy` (§3.5) | `RobotsTxt` |
| `fetch(origin:transport:limits:)` → `Fetched` | `fetch` (§3.6) | `RobotsTxtIO` |

How a crawler's rules are chosen: every group whose user-agent token equals the crawler's (ignoring case) applies, merged; `FooBot/2.1` names `FooBot`. Only if none does, the `*` groups apply. The longest matching pattern decides, `allow` winning ties. Paths and patterns get the same percent-encoding normalization, so `/%7Euser` and `/~user` compare equal. `/robots.txt` itself is always allowed.

`Crawl-delay` is an **extension, not part of RFC 9309**. It's parsed into `Group.crawlDelay` and returned by `crawlDelay`, but never affects `isAllowed`.

`fetch` uses a `Transport`: one GET that doesn't follow redirects, returning the status, `Location` and body, or nil for no response. `URLSessionTransport` is the default; pass your own to use another HTTP client.

## Limits and errors

| Limit | Default | Option |
|---|---|---|
| Bytes of a file that are parsed | 512,000 | `Limits.maxBytes` |
| Redirects `fetch` follows | 5 | `Limits.maxRedirects` |

Past `maxBytes` the rest of the file is ignored, the line the limit cut is dropped, and `RobotsFile.truncated` is set. That's never an error.

Errors are `RobotsError` (typed throws) with a `kind` (`invalidInput`, …) and a stable `code`:

| Code | When |
|---|---|
| `robotstxt.invalid_user_agent` | The user agent is empty or has characters outside `[A-Za-z_-]` |
| `robotstxt.invalid_path` | The path doesn't start with `/` |
| `robotstxt.invalid_origin` | `fetch`: not `http://` or `https://` and an authority only |

The user agent is checked before the path. A failed fetch is a **policy, not an error**: no response, a 429/5xx, or a redirect to a URL that isn't http or https is `disallowAll`; a 4xx, too many redirects, or a redirect with a missing or empty `Location` is `allowAll`.

**Text:** user agents, patterns and sitemaps are reported as UTF-8, with invalid bytes shown as U+FFFD. Matching uses the original bytes.

**HTTP:** `fetch` resolves each `Location` against the current URL per RFC 3986 (dot segments removed, fragment dropped) and follows it itself, so `URLSessionTransport` declines URLSession's automatic redirects. It sends `Accept-Encoding: identity` and stops reading the body after `maxBytes + 1` bytes.

## Modules

| Product | Layer | Needs |
|---|---|---|
| `RobotsTxt` | core | nothing: no Foundation |
| `RobotsTxtIO` | io | Foundation (FoundationNetworking on Linux) for `URLSessionTransport` and URL resolution |

## Development

| Command | What |
|---|---|
| `swift test` | Unit tests: matcher, normalization, truncation, fetch over a scripted transport |
| `swift run robotstxt-conformance` | Every case in `.spec/conformance/manifest.json` |
| `FUZZ_SECONDS=60 swift run -c release robotstxt-fuzz` | Mutation-fuzz `parse`, matching and `fetch` (`FUZZ_SEED` reproduces a run) |
| `swift run -c release robotstxt-bench [dir]` | Timings on the spec's bench input (default `.spec/bench`; method in its `README.md`) |

## Performance

Not recorded yet. The spec's bench input arrives with spec 0.1.1; timings against the reference will be recorded here before the first release.

## Why not CanProceed?

[CanProceed](https://github.com/ptsochantaris/can-proceed) is the existing Swift robots.txt package, and it was checked before this one was written. At the time it fell back to the `*` group when the crawler's own group had no matching rule, ignored product tokens such as `FooBot/2.1`, and removed spaces inside rules, all of which RFC 9309 treats differently. This package follows the spec's reading of the RFC, with conformance cases for each of those points.

## License

MIT OR Apache-2.0
