// Benchmark per `.spec/bench/README.md`: read robots.txt and paths.txt (`user_agent path`
// per line) once; one pass = for each block of consecutive lines with the same crawler, in
// file order: parse robots.txt, then isAllowed for each of the block's paths, summing the
// 1-based line numbers of the allowed ones. 3 warm-up + 15 timed passes; report median and
// min. The sum must match the spec's checksum.
//
//   swift run -c release robotstxt-bench [bench-dir]     (default .spec/bench)

import Foundation
import RobotsTxt

let dir = CommandLine.arguments.dropFirst().first ?? ".spec/bench"
let checksum = 24_281_055
guard let robotsData = FileManager.default.contents(atPath: "\(dir)/robots.txt"),
      let pathsText = try? String(contentsOfFile: "\(dir)/paths.txt", encoding: .utf8) else {
    print("cannot read \(dir)/robots.txt and paths.txt")
    exit(2)
}
let robotsBytes = [UInt8](robotsData)
let lines = pathsText.split(separator: "\n").map { line -> (agent: String, path: String) in
    let parts = line.split(separator: " ", maxSplits: 1)
    return (String(parts[0]), String(parts[1]))
}
// Blocks of consecutive lines for one crawler: (agent, first index, end index).
var blocks: [(agent: String, from: Int, to: Int)] = []
for (i, line) in lines.enumerated() {
    if let last = blocks.last, last.agent == line.agent { blocks[blocks.count - 1].to = i + 1 }
    else { blocks.append((line.agent, i, i + 1)) }
}

var ms = [Double]()
for run in 0..<18 {
    let start = DispatchTime.now().uptimeNanoseconds
    var sum = 0
    for block in blocks {
        let robots = parse(robotsBytes)
        for i in block.from..<block.to where try isAllowed(robots, userAgent: block.agent, path: lines[i].path) {
            sum += i + 1
        }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    precondition(sum == checksum, "checksum \(sum) != \(checksum): wrong answers")
    if run >= 3 { ms.append(elapsed) }
}
ms.sort()
print("robotstxt swift (\(lines.count) lookups, \(blocks.count) parses): pass median "
    + String(format: "%.3f ms (min %.3f), checksum %d ok", ms[7], ms[0], checksum))
