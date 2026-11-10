import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { fatalError("FAIL: " + name) }; checks += 1; print("PASS: " + name) }
let fact = CoachFact(key: "sleep", name: "最近睡眠", value: "7.7 小时", detail: "合成演示 · 个人目标 8.0 小时")
let brief = CoachBrief(title: "回看记录", interpretation: "记录是参考", nextStep: "结合体感", facts: [fact], gaps: ["不连续采样"])
let packet = AICoachPacket(question: "  怎么安排今天？  ", briefs: [brief, brief], synthetic: true)
check(packet.question == "怎么安排今天？", "question normalized")
check(packet.facts.count == 1 && packet.gaps.count == 1, "repeated topic facts and gaps deduplicated")
check(packet.synthetic, "synthetic label retained")
check(packet.json.contains("7.7") && !packet.json.contains("api-key"), "only explicit summary fields serialized")
check(AICoachPacket(question: String(repeating: "问", count: 700), briefs: [], synthetic: false).question.count == 600, "question size bounded")
func response(_ summary: String = "可以先围绕体感安排节奏。", refs: [String] = ["sleep"], observation: String = "最近有睡眠记录，但不能把时长当作恢复保证。", followUps: [String] = ["怎么回看训练后的感受？"]) -> String {
    let row = AICoachAnswer(summary: summary, observations: [.init(text: observation, evidenceKeys: refs)], nextStep: "先核实当前记录，留出短休息，并记录自己的感受。", followUps: followUps)
    return String(data: try! JSONEncoder().encode(row), encoding: .utf8)!
}
check(AICoachContract.parse(response("这些记录可作参考，结合体感安排节奏。"), packet: packet) != nil, "reference is ordinary language, not the financial numeral in 参")
check(AICoachContract.parse(response(), packet: packet) != nil, "genuine non-template narrative with valid evidence accepted")
check(AICoachContract.parse(response(refs: ["invented"]), packet: packet) == nil, "unknown evidence rejected")
check(AICoachContract.parse(response(refs: []), packet: packet) == nil, "unsupported claim without reference rejected")
check(AICoachContract.parse(response(refs: ["sleep", "sleep"]), packet: packet) == nil, "duplicate citations rejected")
check(AICoachContract.parse(response("你的电量是 99。"), packet: packet) == nil, "new numeric score rejected")
check(AICoachContract.parse(response("你睡了 7.7 小时。"), packet: packet) == nil, "even allowed numeric values rendered exclusively by source cards")
check(AICoachContract.parse(response("今天可以练三十分钟。"), packet: packet) == nil, "unsupported Chinese duration rejected")
check(AICoachContract.parse(response("未来一周都会恢复正常。"), packet: packet) == nil, "invented Chinese time forecast rejected")
check(AICoachContract.parse(response("按这个安排保证安全。"), packet: packet) == nil, "guaranteed safety claim rejected")
check(AICoachContract.parse(response("这证明你已经完全恢复。"), packet: packet) == nil, "definite inference rejected")
check(AICoachContract.parse(response(String(repeating: "长", count: 81)), packet: packet) == nil, "summary length bounded")
check(AICoachContract.parse(response(observation: String(repeating: "长", count: 161)), packet: packet) == nil, "observation length bounded")
check(AICoachContract.parse(response(followUps: ["a", "b", "c", "d"]), packet: packet) == nil, "follow-up count bounded")
check(AICoachContract.parse("```json\n" + response() + "\n```", packet: packet) == nil, "non-contract wrapper rejected")
check(AICoachContract.parse("not JSON", packet: packet) == nil, "non-JSON withheld")
let empty = AICoachPacket(question: "为什么没有数据？", briefs: [], synthetic: true)
check(AICoachContract.parse(response(), packet: empty) == nil, "no facts cannot yield cited claims")
let honest = AICoachAnswer(summary: "还缺少可用记录。", observations: [], nextStep: "先检查健康连接与同步。", followUps: [])
check(AICoachContract.parse(String(data: try! JSONEncoder().encode(honest), encoding: .utf8)!, packet: empty) != nil, "honest missing-data response accepted")
var config = AIBackendConfig(cloudEnabled: true, endpoint: "https://mac.local:8787", model: "codex-subscription", hasStoredKey: true)
check(config.cloudUsable && config.normalizedEndpoint == "https://mac.local:8787/v1/chat/completions", "valid HTTPS bridge accepted")
config.endpoint = "http://mac.local:8787"; check(!config.cloudUsable, "plaintext transport rejected")
config.endpoint = "https://user:secret@mac.local"; check(!config.cloudUsable, "credentials in URL rejected")
config.endpoint = "https://mac.local?token=secret"; check(!config.cloudUsable, "credentials in query rejected")
let pairing = AIBridgePairing(endpoint: "https://localhost:8787/v1/chat/completions", model: "codex-subscription", token: String(repeating: "a", count: 48), certificateSHA256: String(repeating: "b", count: 64))
let pairJSON = String(data: try! JSONEncoder().encode(pairing), encoding: .utf8)!
check(AIBridgePairing.parse(pairJSON) != nil, "complete authenticated TLS pairing accepted")
check(AIBridgePairing.parse(pairJSON.replacingOccurrences(of: "https", with: "http")) == nil, "pairing cannot bypass TLS")
check(AIBridgePairing.parse(pairJSON.replacingOccurrences(of: String(repeating: "b", count: 64), with: "wrong")) == nil, "bad certificate pin rejected")
check(AIBridgePairing.parse(pairJSON.replacingOccurrences(of: "codex-subscription", with: "unknown-provider")) == nil, "unexpected pairing provider rejected")
print("\(checks) AI coach contract checks passed; not a model accuracy evaluation.")

if let index = CommandLine.arguments.firstIndex(of: "--live-response"), CommandLine.arguments.count > index + 2 {
    let reply = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
    let livePacket = try JSONDecoder().decode(AICoachPacket.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 2])))
    check(AICoachContract.parse(reply, packet: livePacket) != nil, "actual Codex synthetic response passes the same production contract")
    print("Actual synthetic response validated; not personal physiological validation.")
}
