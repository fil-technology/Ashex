import Foundation

public enum TokenCostPresentationMode: Sendable, Equatable {
    case savings
    case usage
}

public enum TokenSavingsEstimator {
    public static func costPresentationMode(provider: String) -> TokenCostPresentationMode {
        isLocalProvider(provider) ? .savings : .usage
    }

    public static func isLocalProvider(_ provider: String) -> Bool {
        ["ollama", "dflash", "mock"].contains(provider.lowercased())
    }

    public static func estimatedSavedMoneyUSD(for savedTokens: Int, provider: String, model: String) -> Double {
        guard savedTokens > 0 else { return 0 }
        return (Double(savedTokens) / 1_000_000) * avoidedPromptTokenRateUSDPerMillion(provider: provider, model: model)
    }

    public static func estimatedUsageMoneyUSD(for usedTokens: Int, provider: String, model: String) -> Double {
        guard usedTokens > 0 else { return 0 }
        return (Double(usedTokens) / 1_000_000) * promptTokenRateUSDPerMillion(provider: provider, model: model)
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

    public static func avoidedPromptTokenRateUSDPerMillion(provider: String, model: String) -> Double {
        if isLocalProvider(provider) {
            return comparableRemotePromptTokenRateUSDPerMillion(model: model)
        }
        return promptTokenRateUSDPerMillion(provider: provider, model: model)
    }

    private static func comparableRemotePromptTokenRateUSDPerMillion(model: String) -> Double {
        let lowered = model.lowercased()
        if lowered.contains("mini") || lowered.contains("small") || lowered.contains("3b") || lowered.contains("4b") {
            return 0.25
        }
        if lowered.contains("nano") || lowered.contains("1b") || lowered.contains("2b") {
            return 0.05
        }
        return 1.25
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
