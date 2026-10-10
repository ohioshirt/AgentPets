import AgentPetsCore
import Foundation

// hook から呼ばれる。いかなる入力でも exit 0、stdout には何も書かない。spec §3.1。
// Codex は stdout を hook の応答として解釈するため。

let startedAt = Date().timeIntervalSince1970
let debug = ProcessInfo.processInfo.environment["AGENTPETS_HOOK_DEBUG"] == "1"

func log(_ message: String) {
    guard debug else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments
var source: Source?
if let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count {
    source = Source(rawValue: arguments[index + 1])
}

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let source, source != .manual else {
    log("ignored: --source must be claude or codex")
    exit(0)
}
guard let event = HookNormalizer.normalize(source: source, stdin: input, now: startedAt),
      let payload = WireCodec.encode(event) else {
    log("ignored: not a mapped hook event")
    exit(0)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(WireCodec.notificationName),
    object: payload,
    userInfo: nil,
    deliverImmediately: true
)
log(payload)
exit(0)
