import Foundation
import Combine
import WatchConnectivity

@MainActor final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchBridge()
    @Published var status = StatusStore.read()
    @Published var connection = "等待同步"
    var actionTitle:String?
    var actionDate:Date?
    @Published var inbox:[WatchCheckIn] = []
    private var inboxURL:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("pocket-watch-inbox.json")}
    private func persistInbox(){try? FileManager.default.createDirectory(at:inboxURL.deletingLastPathComponent(),withIntermediateDirectories:true);if let data=try? JSONEncoder().encode(inbox){try? data.write(to:inboxURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}}
    func acknowledge(_ id:UUID){inbox.removeAll{$0.id == id};persistInbox()}
    func sendCheckIn(energy:Int){
        guard !status.demo else{connection="演示模式不发送真实自评";return}
        let row=WatchCheckIn(date:Date(),energy:energy)
        guard row.valid(now:Date()),WCSession.isSupported(),WCSession.default.activationState == .activated,let data=try? JSONEncoder().encode(row) else{connection="请等待手表与手机连接后重试";return}
        WCSession.default.transferUserInfo(["checkin":data]);connection="已交给系统传送，待 iPhone 接收"
    }
    var presentationOverride: PocketStatus?
    func publishHealth(_ value: PocketStatus) { publish(presentationOverride ?? value) }
    private override init() {
        super.init()
        #if os(iOS)
        if status.demo { status = .empty }
        inbox=(try? JSONDecoder().decode([WatchCheckIn].self,from:Data(contentsOf:inboxURL))) ?? []
        #endif
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func publish(_ incoming: PocketStatus) {
        var value = incoming
        #if os(iOS)
        // Sequence presentation changes (including clearing demo) by publication time.
        // measuredAt remains untouched, so republishing cannot make old observations fresh.
        value.computedAt = Date()
        value.actionTitle=actionTitle;value.actionDate=actionDate
        #endif
        status = value
        let saved = StatusStore.save(value)
        connection = saved ? "组件摘要已更新" : "组件共享容器不可用；需检查 App Group 签名"
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(value) else { return }
        do { try WCSession.default.updateApplicationContext(["status": data]) }
        catch { connection = "手表暂未同步；摘要保留在本机" }
    }
    func requestLatest() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { connection = "请在配对的 iPhone 打开 App 刷新"; return }
        WCSession.default.sendMessage(["refresh": true], replyHandler: { reply in
            if let data = reply["status"] as? Data { Task { @MainActor in self.accept(data) } }
        }, errorHandler: { _ in Task { @MainActor in self.connection = "连接暂不可用，请稍后重试" } })
    }
    private func accept(_ data: Data) {
        guard let value = try? JSONDecoder().decode(PocketStatus.self, from: data), value.computedAt >= status.computedAt, value.computedAt <= Date().addingTimeInterval(60) else { return }
        status = value
        connection = StatusStore.save(value) ? "已收到 iPhone 摘要" : "收到摘要，组件存储失败"
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            #if os(watchOS)
            if let data = session.receivedApplicationContext["status"] as? Data { self.accept(data) }
            #endif
            #if os(iOS)
            self.publish(self.status)
            #endif
        }
    }
    nonisolated func session(_ session:WCSession,didReceiveUserInfo userInfo:[String:Any]) {
        #if os(iOS)
        guard let data=userInfo["checkin"] as? Data,data.count < 10000,let row=try? JSONDecoder().decode(WatchCheckIn.self,from:data),row.valid(now:Date()) else{return}
        Task{@MainActor in if !self.inbox.contains(where:{$0.id == row.id}){self.inbox.append(row);self.persistInbox()}}
        #endif
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        #if os(watchOS)
        if let data = applicationContext["status"] as? Data { Task { @MainActor in self.accept(data) } }
        #endif
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            if let data = try? JSONEncoder().encode(self.status) { replyHandler(["status": data]) } else { replyHandler([:]) }
        }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
