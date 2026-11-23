import Foundation

/// Runs a bounded number of independent jobs concurrently. Only cancellation escapes the batch.
enum ConcurrentJobs {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output?).self) { group in
            var nextIndex = 0
            var ordered = Array<Output?>(repeating: nil, count: inputs.count)

            func submit(_ index: Int, _ input: Input) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let value = try await operation(input)
                        try Task.checkCancellation()
                        return (index, value)
                    } catch {
                        if error is CancellationError || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        try Task.checkCancellation()
                        return (index, nil)
                    }
                }
            }

            for _ in 0..<min(limit, inputs.count) {
                submit(nextIndex, inputs[nextIndex])
                nextIndex += 1
            }

            do {
                while let (index, output) = try await group.next() {
                    try Task.checkCancellation()
                    ordered[index] = output
                    if nextIndex < inputs.count {
                        submit(nextIndex, inputs[nextIndex])
                        nextIndex += 1
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            try Task.checkCancellation()
            return ordered.compactMap { $0 }
        }
    }
}
