import Foundation
import CoreGraphics

let kw = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "war3"
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("ERR no list")
    exit(1)
}
for w in list {
    let o = w[kCGWindowOwnerName as String] as? String ?? "?"
    let n = w[kCGWindowName as String] as? String ?? ""
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let r = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = r["X"] as? Double ?? -1, y = r["Y"] as? Double ?? -1
    let ww = r["Width"] as? Double ?? -1, hh = r["Height"] as? Double ?? -1
    let low = (o + " " + n).lowercased()
    if low.contains(kw) {
        print("ID=\(id) PID=\(pid) LAYER=\(layer) ONSCREEN=\(onscreen) RECT=(\(Int(x)),\(Int(y)) \(Int(ww))x\(Int(hh))) OWNER=[\(o)] NAME=[\(n)]")
    }
}