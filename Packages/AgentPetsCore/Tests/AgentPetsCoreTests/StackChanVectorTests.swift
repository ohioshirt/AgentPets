import Foundation
import Testing
@testable import AgentPetsCore

/// `Fixtures/stackchan/state-record-v1.txt` の 1 行。
private enum Vector {
    case accept(record: [UInt8], status: UInt8, seq: UInt8, text: [UInt8], line: Int)
    case reject(record: [UInt8], reason: String, line: Int)
}

private struct VectorFormatError: Error, CustomStringConvertible {
    let line: Int
    let why: String
    var description: String { "state-record-v1.txt:\(line): \(why)" }
}

private let rejectReasons: Set<String> = ["short", "version", "status", "length", "utf8"]

private func hex(_ s: Substring, line: Int) throws -> [UInt8] {
    // 空のバイト列は `-` と書く。空欄はファームウェアと同じく書式の誤りにする。
    guard !s.isEmpty, s.count % 2 == 0, s.allSatisfy({ "0123456789abcdef".contains($0) }) else {
        throw VectorFormatError(line: line, why: "hex は小文字・偶数桁・区切りなし: \(s)")
    }
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        bytes.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return bytes
}

private func field(_ s: Substring, _ name: String, line: Int) throws -> Substring {
    guard s.hasPrefix(name + "=") else { throw VectorFormatError(line: line, why: "\(name)= が無い: \(s)") }
    return s.dropFirst(name.count + 1)
}

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "state-record-v1", withExtension: "txt",
                                              subdirectory: "Fixtures/stackchan"))
    let content = try String(contentsOf: url, encoding: .utf8)
    // Swift では "\r\n" が 1 つの Character なので "\n" で割れず、CRLF のコメント行は次の行を
    // 飲み込んで黙って読み飛ばす。CR はどこにあっても書式の誤りにする。
    if let cr = content.utf8.firstIndex(of: 0x0D) {
        let line = content.utf8[..<cr].count(where: { $0 == 0x0A }) + 1
        throw VectorFormatError(line: line, why: "CR を含む（改行は LF のみ）")
    }
    var vectors: [Vector] = []
    for (index, raw) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = index + 1
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: false)
        switch parts.first {
        case "accept":
            guard parts.count == 5 else { throw VectorFormatError(line: line, why: "accept は 5 欄") }
            let status = try field(parts[2], "status", line: line)
            let seq = try field(parts[3], "seq", line: line)
            let text = try field(parts[4], "text", line: line)
            guard let statusValue = UInt8(status), statusValue <= 4, let seqValue = UInt8(seq) else {
                throw VectorFormatError(line: line, why: "status は 0-4、seq は 0-255")
            }
            vectors.append(.accept(record: try hex(parts[1], line: line), status: statusValue, seq: seqValue,
                                   text: text == "-" ? [] : try hex(text, line: line), line: line))
        case "reject":
            guard parts.count == 3, rejectReasons.contains(String(parts[2])) else {
                throw VectorFormatError(line: line, why: "reject <hex> <short|version|status|length|utf8>")
            }
            vectors.append(.reject(record: try hex(parts[1], line: line), reason: String(parts[2]), line: line))
        default:
            throw VectorFormatError(line: line, why: "accept / reject / # 以外で始まる行")
        }
    }
    return vectors
}

/// spec §1.3 の受信規則を、ファームウェアと同じ順で判定する（ベクタ自体の検算用）。
/// UTF-8 の判定は標準ライブラリの `String(validating:as:)` に任せる。
private func rejectReason(_ r: [UInt8]) -> String? {
    if r.count < 4 { return "short" }
    if r[0] != 1 { return "version" }
    if r[1] > 4 { return "status" }
    if Int(r[3]) != r.count - 4 { return "length" }
    if String(validating: r.dropFirst(4), as: UTF8.self) == nil { return "utf8" }
    return nil
}

/// 順序に頼らず、破っている規則をすべて挙げる。全長 4 未満のときは他の規則を見ない。
/// 「reject の各行は規則を 1 つだけ破る」の検査用（`rejectReason` は最初の 1 つしか返さない）。
private func brokenRules(_ r: [UInt8]) -> Set<String> {
    if r.count < 4 { return ["short"] }
    var broken = Set<String>()
    if r[0] != 1 { broken.insert("version") }
    if r[1] > 4 { broken.insert("status") }
    if Int(r[3]) != r.count - 4 { broken.insert("length") }
    if String(validating: r.dropFirst(4), as: UTF8.self) == nil { broken.insert("utf8") }
    return broken
}

private let statuses: [PetStatus] = [.idle, .working, .waiting, .success, .error]

@Suite("StackChan テストベクタ（ファームウェアと共有）")
struct StackChanVectorTests {
    @Test("ファイルが読め、受理・拒否の各種が揃っている（空ファイルで素通りしない）")
    func coverage() throws {
        let vectors = try loadVectors()
        var acceptedStatuses = Set<UInt8>()
        var reasons = Set<String>()
        var lengths = Set<Int>()
        for v in vectors {
            switch v {
            case let .accept(record, status, _, text, _):
                acceptedStatuses.insert(status)
                lengths.insert(text.count)
                #expect(record.count == 4 + text.count)
            case let .reject(_, reason, _):
                reasons.insert(reason)
            }
        }
        #expect(acceptedStatuses == [0, 1, 2, 3, 4])
        #expect(reasons == rejectReasons)
        #expect(lengths.contains(0))
        #expect(lengths.contains(255))
    }

    @Test("accept の各行は Swift の encode と 1 バイトも違わない")
    func acceptRoundTrips() throws {
        for case let .accept(record, status, seq, text, line) in try loadVectors() {
            let subtitle = try #require(String(validating: text, as: UTF8.self), "line \(line)")
            let display = DisplayState(status: statuses[Int(status)], message: "", subtitle: subtitle, sessionKey: nil)
            let encoded = StackChanRecord.encode(display, celebrateSeq: seq, maxLength: StackChanRecord.maxRecordLength)
            #expect(encoded.map(Array.init) == record, "line \(line)")
            #expect(rejectReason(record) == nil, "line \(line)")
        }
    }

    @Test("reject の各行は、書かれた理由で受信規則に落ちる")
    func rejectsMatchReason() throws {
        for case let .reject(record, reason, line) in try loadVectors() {
            #expect(rejectReason(record) == reason, "line \(line)")
        }
    }

    @Test("reject の各行は規則を 1 つだけ破る（判定の順序が違う受信側でも同じ理由になる）")
    func rejectsBreakExactlyOneRule() throws {
        for case let .reject(record, reason, line) in try loadVectors() {
            #expect(brokenRules(record) == [reason], "line \(line)")
        }
    }

    @Test("accept 行に 4 バイトの UTF-8 がある")
    func acceptsFourByteUTF8() throws {
        let texts = try loadVectors().compactMap { v -> [UInt8]? in
            if case let .accept(_, _, _, text, _) = v { return text } else { return nil }
        }
        #expect(texts.contains { $0.contains { $0 >= 0xf0 } })
    }
}
