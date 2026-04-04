import AshexCore
import Foundation

struct ConsoleApprovalPolicy: ApprovalPolicy {
    let mode: ApprovalMode = .guarded

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        let prompt = """

        Approval required
        Tool: \(request.toolName)
        Summary: \(request.summary)
        Target: \(request.reason)
        Risk: \(request.risk.rawValue)
        Allow? [y/N]:
        """

        fputs(prompt + " ", stdout)
        fflush(stdout)
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .deny("No approval response received")
        }
        return response == "y" || response == "yes"
            ? .allow("Approved in guarded mode")
            : .deny("Denied in guarded mode")
    }
}
