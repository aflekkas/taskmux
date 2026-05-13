import Foundation

/// Local-only diagnostics hooks. Taskmux keeps these call sites as no-ops so
/// the app has no hosted crash-reporting dependency.
func diagnosticsBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {}

func diagnosticsCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {}

func diagnosticsCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {}

final class FocusLogStore {
    static let shared = FocusLogStore()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 500

    private init() {}

    func append(_ message: String) {
        lock.lock()
        lines.append(message)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let value = lines.joined(separator: "\n")
        lock.unlock()
        return value
    }

    func logPath() -> String {
        "/tmp/cmux-focus.log"
    }
}
