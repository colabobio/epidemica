import Foundation
import ProximityWire

/// Bounded FIFO holding detections observed while Dart was not listening.
///
/// iOS relaunches an app in the background for Bluetooth work, and the Flutter engine is often not
/// attached when the radio starts reporting. Dropping those detections would bias the record in a
/// specific direction — the loss lands on unattended background encounters, which are exactly the
/// long ones a transmission study is trying to measure — so they are buffered, and any overflow is
/// counted and reported rather than swallowed.
final class DetectionBuffer {

    /// Roughly a day of detections for a busy participant. Overflow should mean something has gone
    /// wrong, not that the participant went to a concert.
    static let defaultCapacity = 8192

    struct Drained {
        let events: [[String: Any]]
        let dropped: Int
        let oldestRetainedMs: Int64?
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    private var dropped = 0

    init(capacity: Int = DetectionBuffer.defaultCapacity) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    func add(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        while entries.count >= capacity {
            entries.removeFirst()
            dropped += 1
        }
        entries.append(event)
    }

    /// Empties the buffer and resets the drop counter, which the caller now owns.
    func drain() -> Drained {
        lock.lock()
        defer { lock.unlock() }
        let drained = Drained(
            events: entries,
            dropped: dropped,
            oldestRetainedMs: entries.first?["observed_at_ms"] as? Int64)
        entries.removeAll(keepingCapacity: true)
        dropped = 0
        return drained
    }
}

/// The single point where native detections meet the Dart event stream.
///
/// Everything goes through the buffer, even when Dart is attached. That removes the attach race
/// outright rather than papering over it: there is no window in which an event can be produced,
/// find no listener, and vanish.
final class ProximityEvents {

    static let shared = ProximityEvents()

    private let buffer = DetectionBuffer()
    private var sink: ((Any) -> Void)?

    func attach(_ sink: @escaping (Any) -> Void) {
        self.sink = sink
        flush()
    }

    func detach() {
        sink = nil
    }

    func emit(_ event: [String: Any]) {
        buffer.add(event)
        flush()
    }

    private func flush() {
        guard sink != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let sink = self.sink else { return }
            let drained = self.buffer.drain()
            // Announced before the survivors, because it describes the gap that precedes them.
            if drained.dropped > 0 {
                var event: [String: Any] = ["type": "dropped", "count": drained.dropped]
                if let oldest = drained.oldestRetainedMs { event["oldest_retained_ms"] = oldest }
                sink(event)
            }
            for event in drained.events { sink(event) }
        }
    }
}
