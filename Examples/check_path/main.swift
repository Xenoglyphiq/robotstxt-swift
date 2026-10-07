// Canonical example `check_path`: parse a sample robots.txt and print whether
// NowhereToBeBot may fetch /private/page.
// Usage: swift run check_path [path]
import RobotsTxt

let sample = """
    # Sample robots.txt
    User-agent: *
    Disallow: /search
    Allow: /private/press

    User-agent: NowhereToBeBot
    Disallow: /private/
    Allow: /private/press/

    Sitemap: https://example.com/sitemap.xml
    Sitemap: https://example.com/news/sitemap.xml
    """

let path = CommandLine.arguments.dropFirst().first ?? "/private/page"
let robots = parse(sample)
do {
    let allowed = try isAllowed(robots, userAgent: "NowhereToBeBot", path: path)
    print("NowhereToBeBot \(allowed ? "may" : "may not") fetch \(path)")
} catch {
    print("error: \(error)")
}
