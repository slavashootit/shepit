import Foundation
import Network

/// Tracks whether the Mac has any usable network path, so dictation can skip
/// online steps up front instead of waiting for them to time out.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ua.slava.shepit.network", qos: .utility)
    private(set) var isOnline = true

    /// Called on the main queue whenever reachability flips.
    var onChange: ((Bool) -> Void)?

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, online != self.isOnline else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }
}
