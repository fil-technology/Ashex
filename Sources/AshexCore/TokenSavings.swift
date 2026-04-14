import Foundation

public enum TokenSavingsEstimator {
    public static func estimatedSavedMoneyUSD(for savedTokens: Int, provider: String, model: String) -> Double {
        guard savedTokens > 0 else { return 0 }
        return (Double(savedTokens) / 1_000_000) * promptTokenRateUSDPerMillion(provider: provider, model: model)
    }

    public static func promptTokenRateUSDPerMillion(provider: String, model: String) -> Double {
        let lowered = model.lowercased()
        switch provider {
        case "openai":
            if lowered.contains("mini") { return 0.25 }
            if lowered.contains("nano") { return 0.05 }
            return 1.25
        case "anthropic":
            return 3.00
        case "ollama", "dflash", "mock":
            return 0
        default:
            return 1.00
        }
    }

    public static func formatUSD(_ dollars: Double) -> String {
        if dollars >= 1_000 {
            return String(format: "$%.1fk", dollars / 1_000)
        }
        if dollars >= 1 {
            return String(format: "$%.2f", dollars)
        }
        if dollars > 0 {
            return String(format: "$%.3f", dollars)
        }
        return "$0.00"
    }
}
