import Foundation
import Observation

/// Collects messages the reader has actually seen and reports them in batches.
///
/// Read state belongs to the server — a message read here has to look read on every other
/// device — so it is sent onward rather than only written locally. Batching keeps a fast
/// scroll from turning into one request per message.
@MainActor
@Observable
final class ReadTracker {
    private var pending: Set<Int> = []
    private var flushTask: Task<Void, Never>?
    private let flush: ([Int]) async -> Void

    /// Long enough to gather a scroll, short enough that leaving immediately still reports.
    private static let delay = Duration.milliseconds(600)

    init(flush: @escaping ([Int]) async -> Void) {
        self.flush = flush
    }

    func sawMessage(id: Int) {
        pending.insert(id)
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    func flushNow() async {
        guard !pending.isEmpty else { return }
        let batch = Array(pending)
        pending = []
        await flush(batch)
    }
}
