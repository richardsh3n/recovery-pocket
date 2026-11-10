import Foundation
import HealthKit

/// Reference integration for the future food app, not compiled into Recovery Pocket.
struct PhotoMealEstimate: Codable {
    struct Food: Codable {
        var name: String
        var estimatedGrams: Double?
        var kcal: Double
        var lowerKcal: Double
        var upperKcal: Double
        var basis: String
    }
    var schemaVersion: Int
    var mealID: UUID
    var revision: Int
    var eatenAt: Date
    var userConfirmed: Bool
    var totalKcal: Double
    var lowerKcal: Double
    var upperKcal: Double
    var foods: [Food]
    var assumptions: [String]
    var questions: [String]
    func validate(at now:Date = Date()) throws {
        func range(_ lo:Double,_ mid:Double,_ hi:Double) -> Bool { lo.isFinite && mid.isFinite && hi.isFinite && lo >= 0 && lo <= mid && mid <= hi }
        guard schemaVersion == 1,revision >= 1,eatenAt <= now,userConfirmed,!foods.isEmpty,
              range(lowerKcal,totalKcal,upperKcal),foods.allSatisfy({ !$0.name.isEmpty && range($0.lowerKcal,$0.kcal,$0.upperKcal) && ($0.estimatedGrams == nil || $0.estimatedGrams.map { $0.isFinite && $0 > 0 } == true) }),
              abs(foods.reduce(0) { $0+$1.kcal }-totalKcal) <= 1,
              abs(foods.reduce(0) { $0+$1.lowerKcal }-lowerKcal) <= 1,
              abs(foods.reduce(0) { $0+$1.upperKcal }-upperKcal) <= 1 else { throw WriterError.invalidOrUnconfirmedMeal }
    }
    enum WriterError: Error { case invalidOrUnconfirmedMeal }
}
@MainActor final class PhotoMealHealthWriter {
    private let health = HKHealthStore()
    private let type = HKQuantityType.quantityType(forIdentifier:.dietaryEnergyConsumed)!
    /// Invoke from a human-operated food-app button. App needs its own HealthKit
    /// entitlement and NSHealthUpdateUsageDescription; Pocket remains read-only.
    func requestWritePermission() async throws {
        try await health.requestAuthorization(toShare:[type],read:[])
    }
    func writeConfirmedMeal(_ meal:PhotoMealEstimate) async throws {
        try meal.validate()
        let metadata:[String:Any] = [HKMetadataKeySyncIdentifier:"rfg-meal-"+meal.mealID.uuidString,
            HKMetadataKeySyncVersion:meal.revision,
            "studio.rfg.food.estimateLowerKcal":meal.lowerKcal,
            "studio.rfg.food.estimateUpperKcal":meal.upperKcal,
            "studio.rfg.food.estimateMethod":"photo_ai_user_confirmed"]
        let sample = HKQuantitySample(type:type,quantity:HKQuantity(unit:.kilocalorie(),doubleValue:meal.totalKcal),start:meal.eatenAt,end:meal.eatenAt,metadata:metadata)
        try await health.save(sample)
    }
}
