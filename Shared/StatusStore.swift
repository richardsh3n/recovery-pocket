import Foundation
import WidgetKit

enum StatusStore {
    static let group = "group.studio.rfg.recoverypocket"
    private static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("status.json") }
    static func read() -> PocketStatus {
        guard let url, let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(PocketStatus.self, from: data) else { return .empty }
        return value
    }
    @discardableResult static func save(_ value: PocketStatus) -> Bool {
        guard let url else {
            #if DEBUG
            print("Pocket summary save failed: App Group URL unavailable")
            #endif
            return false
        }
        let data: Data
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            data = try encoder.encode(value)
            if let oldData=try? Data(contentsOf:url),var old=try? JSONDecoder().decode(PocketStatus.self,from:oldData){
                old.computedAt=value.computedAt
                if try encoder.encode(old) == data {return true}
            }
        }
        catch {
            #if DEBUG
            print("Pocket summary encoding failed: \((error as NSError).domain) \((error as NSError).code)")
            #endif
            return false
        }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var resourceURL = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try resourceURL.setResourceValues(flags)
            WidgetCenter.shared.reloadAllTimelines(); return true
        } catch {
            #if DEBUG
            print("Pocket summary write failed: \((error as NSError).domain) \((error as NSError).code)")
            #endif
            return false
        }
    }
}
