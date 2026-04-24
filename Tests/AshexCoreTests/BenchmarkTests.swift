import AshexCore
import Foundation
import Testing

@Test func bundledBenchmarkSuitesLoad() throws {
    let suites = try BenchmarkLoader.bundledSuiteURLs().map { try BenchmarkLoader.loadSuite(from: $0) }

    #expect(suites.count >= 6)
    #expect(suites.flatMap(\.cases).contains { $0.category == .reasoning })
    #expect(suites.flatMap(\.cases).contains { $0.category == .agentic })
    #expect(suites.flatMap(\.cases).contains { $0.category == .toolUse })
    #expect(suites.flatMap(\.cases).contains { $0.category == .coding })
    #expect(suites.flatMap(\.cases).contains { $0.category == .recovery })
    #expect(suites.flatMap(\.cases).contains { $0.category == .memory })
}

@Test func benchmarkScorerChecksTextNumbersAndTools() {
    let benchmarkCase = BenchmarkCase(
        id: "reasoning.loan.monthly_payment.001",
        category: .reasoning,
        title: "Loan monthly payment estimation",
        prompt: "Estimate the monthly payment.",
        expected: .init(
            mustContain: ["monthly payment", "interest"],
            mustNotContain: ["probably"],
            approxNumericAnswer: .init(value: 2120, tolerancePercent: 8),
            toolActions: ["read_file"],
            requiresToolUse: true
        ),
        scoring: .init(maxScore: 10)
    )

    let score = BenchmarkScorer.score(
        case: benchmarkCase,
        outcome: .init(
            finalAnswer: "The monthly payment is about 2,115 with interest included.",
            toolActions: ["read_file"],
            toolSuccesses: [true],
            errors: []
        )
    )

    #expect(score.score == 10)
    #expect(score.failures.isEmpty)
}

@Test func benchmarkMarkdownReportIncludesSummaryAndFailures() {
    let summary = BenchmarkRunSummary(
        suiteID: "demo",
        suiteTitle: "Demo",
        provider: "mock",
        model: "mock-rule-based",
        startedAt: Date(timeIntervalSince1970: 0),
        finishedAt: Date(timeIntervalSince1970: 1),
        results: [
            .init(
                id: "case.001",
                category: .coding,
                title: "Case",
                score: 5,
                maxScore: 10,
                passed: false,
                durationSeconds: 1,
                finalAnswer: "answer",
                toolActions: [],
                failures: ["mustContain:fix"],
                error: nil
            ),
        ]
    )

    let markdown = BenchmarkReportWriter.markdown(for: summary)

    #expect(markdown.contains("Ashex Benchmark Report"))
    #expect(markdown.contains("mock/mock-rule-based"))
    #expect(markdown.contains("mustContain:fix"))
}
