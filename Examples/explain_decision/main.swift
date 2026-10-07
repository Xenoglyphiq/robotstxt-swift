// Canonical example `explain_decision`: print the rule (allow or disallow, pattern,
// line) that decides a path for a crawler, or that no rule does.
// Usage: swift run explain_decision [path] [user-agent]
import RobotsTxt

let sample = """
    # Sample robots.txt
    User-agent: *
    Disallow: /search

    User-agent: NowhereToBeBot
    Disallow: /private/
    Allow: /private/press/
    Disallow: /*.pdf$
    """

let args = Array(CommandLine.arguments.dropFirst())
let path = args.first ?? "/private/press/2026.html"
let agent = args.count > 1 ? args[1] : "NowhereToBeBot"
let robots = parse(sample)
do {
    if let rule = try matchingRule(robots, userAgent: agent, path: path) {
        print("\(agent) \(path): \(rule.allow ? "allow" : "disallow") \(rule.pattern) (line \(rule.line))")
    } else {
        print("\(agent) \(path): no rule applies, so it is allowed")
    }
} catch {
    print("error: \(error)")
}
