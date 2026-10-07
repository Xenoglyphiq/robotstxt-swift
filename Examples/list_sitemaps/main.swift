// Canonical example `list_sitemaps`: parse a sample robots.txt and print its sitemap
// URLs in file order.
// Usage: swift run list_sitemaps
import RobotsTxt

let sample = """
    # Sample robots.txt
    Sitemap: https://example.com/sitemap.xml
    User-agent: *
    Disallow: /search
    Sitemap: https://example.com/news/sitemap.xml

    User-agent: NowhereToBeBot
    Disallow: /private/
    Sitemap: https://example.com/archive/sitemap.xml
    """

for url in parse(sample).sitemaps {
    print(url)
}
