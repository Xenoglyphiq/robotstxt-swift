# Contributing to robots.txt for Swift

Thanks for helping. This package is one of several language ports of the same spec, and all of them must behave identically.

## How this repo works

- The package itself lives at the repo root, laid out the way Swift expects: `Package.swift`, `Sources/RobotsTxt` (core, no Foundation) and `Sources/RobotsTxtIO` (io). Tooling lives in `Sources/robotstxt-*` and `Examples/`.
- **`.spec/`** is a copy of the spec and its conformance cases from **`Xenoglyphiq/robotstxt-spec`**, at the version in `.spec/SPEC_VERSION`. Don't edit it here; it's replaced when the port moves to a newer spec.
- **`.kit/`** holds shared conventions, schemas and the validator. Don't edit it here either.

Read `.kit/CONVENTIONS.md` and `.spec/spec/SPEC.md` before changing behavior.

## Where to send a change

| You want to… | Where |
|---|---|
| Fix a bug in this port | Here. Add a test or point to the conformance case it fixes |
| Change how the library behaves | The spec repo `Xenoglyphiq/robotstxt-spec`. Open an issue there first |
| Report that this port behaves differently from another | The spec repo, with the input; it becomes a conformance case |
| Improve docs or examples for this port | Here |

## Checks every PR must pass

1. `uv run .kit/validate.py .spec`
2. Build and unit tests: `swift test` (macOS and Linux)
3. Conformance runner: `swift run robotstxt-conformance`; every claimed level must pass
4. The three canonical examples: `swift run check_path`, `list_sitemaps`, `explain_decision`

## Style

- Follow Swift's own conventions for names, errors and packaging.
- Errors keep the kinds and codes from the spec; tests assert kind and code, never message text.
- Every public item has a doc comment naming the spec operation it implements.

## License

By contributing you agree your contribution is licensed under MIT OR Apache-2.0, the same as this project.
