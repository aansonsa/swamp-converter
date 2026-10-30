import Foundation

// Generates the `conformance.*` self-tests from the operation registry: one test per operation, plus the coverage test that fails when an operation has
// no CONTENT oracle (the generic fallback does not count). Called from CoreTests.register(), i.e. after every engine registered its operations (Harness.runSelfTests does registerAll first).

enum ConformanceGate {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("conformance.coverage", "every registered operation is claimed by a content oracle (not the generic fallback) or exempt with a reason; the report lists who proves what", timeout: 60) {
            let registry = ConformanceRegistry.shared
            var uncovered: [String] = []
            var fallbackOnly: [String] = []
            var byOracle: [String: [String]] = [:]
            var exempt = 0
            for op in OperationRegistry.shared.allOperations() {
                if registry.exemption(for: op.meta) != nil { exempt += 1; continue }
                // Covered = a real oracle judges the CONTENT of the output. The generic fallback only runs the anti-fake checks, so it never counts.
                guard let o = registry.coveringOracle(for: op.meta) else {
                    uncovered.append(op.id)
                    if registry.oracle(for: op.meta) != nil { fallbackOnly.append(op.id) }
                    continue
                }
                byOracle[o.id, default: []].append(op.id)
            }
            for (id, ops) in byOracle.sorted(by: { $0.key < $1.key }) {
                let proves = registry.allOracles.first { $0.id == id }?.proves ?? ""
                out("      \(id) (\(ops.count)): \(proves)")
            }
            if !fallbackOnly.isEmpty { out("      only the generic anti-fake checks apply to (UNCOVERED): \(fallbackOnly.sorted().joined(separator: ", "))") }
            out("      \(byOracle.values.reduce(0) { $0 + $1.count }) operations covered, \(exempt) exempt, \(uncovered.count) uncovered")
            try expect(uncovered.isEmpty, "operations without a content oracle (the generic fallback does not count): \(uncovered.sorted().joined(separator: ", ")). Add an oracle with ConformanceRegistry.shared.add or exempt the operation with a reason")
        }

        for op in OperationRegistry.shared.allOperations() where ConformanceRegistry.shared.exemption(for: op.meta) == nil {
            let id = op.meta.id
            let heavy: Set<OperationFamily> = [.video, .download]
            t.register("conformance.\(op.meta.family.rawValue)", "\(id): a real conversion with the right format, decodable, faithful to the source",
                       requires: op.meta.requires.map { "tool.\($0.rawValue)" }, timeout: heavy.contains(op.meta.family) || id.hasPrefix("smart.") || id.hasPrefix("fit.") ? 600 : 240) {
                try await ConformanceRunner.test(operationID: id)
            }
        }
    }
}
