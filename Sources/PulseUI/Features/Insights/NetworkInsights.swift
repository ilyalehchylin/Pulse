// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import Foundation
import Combine

/// Collects insights about the current session.
final class NetworkLoggerInsights: @unchecked Sendable {
    private var cancellable: AnyCancellable?

    var transferSize: NetworkLogger.TransferSizeInfo { main.transferSize }
    var duration: RequestsDurationInfo { main.duration }
    var redirects: RedirectsInfo { main.redirects }
    var failures: FailuresInfo { main.failures }

    private var main = Contents()
    private var contents = Contents()

    private struct Contents {
        var transferSize = NetworkLogger.TransferSizeInfo()
        var duration = RequestsDurationInfo()
        var redirects = RedirectsInfo()
        var failures = FailuresInfo()
    }

    static let shared = NetworkLoggerInsights()

    let didUpdate = PassthroughSubject<Void, Never>()

    private let queue = DispatchQueue(label: "com.githun.kean.network-logger-insights")

    /// Registers a given store. Only one store can be registered.
    func register(store: LoggerStore) {
        cancellable = store.events.receive(on: queue).sink { [weak self] in
            self?.process(event: $0)
        }
    }

    private func process(event: LoggerStore.Event) {
        switch event {
        case .messageStored: break
        case .networkTaskCreated: break
        case .networkTaskProgressUpdated: break
        case .networkTaskCompleted(let event): process(event: event)
        }
    }

    private func process(event: LoggerStore.Event.NetworkTaskCompleted) {
        guard let metrics = event.metrics else { return }

        contents.transferSize = contents.transferSize.merging(metrics.totalTransferSize)
        contents.duration.insert(duration: TimeInterval(metrics.taskInterval.duration), taskId: event.taskId)
        if metrics.redirectCount > 0 {
            contents.redirects.count += metrics.redirectCount
            contents.redirects.taskIds.append(event.taskId)
            contents.redirects.timeLost += metrics.transactions
                .filter({ $0.response?.statusCode == 302 })
                .map { $0.timing.duration ?? 0 }
                .reduce(0, +)
        }

        if event.error != nil {
            contents.failures.taskIds.append(event.taskId)
        }

        let contents = self.contents

        DispatchQueue.main.async {
            self.main = contents
            self.didUpdate.send(())
        }
    }

    func reset() {
        queue.async {
            self.contents = .init()
            DispatchQueue.main.async {
                self.main = .init()
                self.didUpdate.send(())
            }
        }
    }

    struct RequestsDurationInfo: Sendable {
        var median: TimeInterval?
        var maximum: TimeInterval?
        var minimum: TimeInterval?

        /// Sorted list of all recorded durations.
        var values: [TimeInterval] = []

        /// Contains top slowest requests.
        var topSlowestRequests: [UUID: TimeInterval] = [:]

        mutating func insert(duration: TimeInterval, taskId: UUID) {
            values.insert(duration, at: insertionIndex(for: duration))
            median = values[values.count / 2]
            if let maximum = self.maximum {
                self.maximum = max(maximum, duration)
            } else {
                self.maximum = duration
            }
            if let minimum = self.minimum {
                self.minimum = min(minimum, duration)
            } else {
                self.minimum = duration
            }
            topSlowestRequests[taskId] = duration
            if topSlowestRequests.count > 10 {
                let max = topSlowestRequests.max(by: { $0.value > $1.value })
                topSlowestRequests[max!.key] = nil
            }
        }

        private func insertionIndex(for duration: TimeInterval) -> Int {
            var lowerBound = 0
            var upperBound = values.count
            while lowerBound < upperBound {
                let mid = lowerBound + (upperBound - lowerBound) / 2
                if values[mid] == duration {
                    return mid
                } else if values[mid] < duration {
                    lowerBound = mid + 1
                } else {
                    upperBound = mid
                }
            }
            return lowerBound
        }
    }

    struct RedirectsInfo: Sendable {
        /// A single task can be redirected multiple times.
        var count: Int = 0
        var timeLost: TimeInterval = 0
        var taskIds: [UUID] = []

        init() {}
    }

    struct FailuresInfo: Sendable {
        var count: Int { taskIds.count }
        var taskIds: [UUID] = []

        init() {}
    }
}
