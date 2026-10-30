import Foundation
import Network

@MainActor
final class ConnectivityService: ObservableObject {
    @Published private(set) var isConnected = true
    @Published var serverUnreachable = false
    var isOffline: Bool { !isConnected || serverUnreachable }
    var onReconnect: (() -> Void)?
    private let monitor = NWPathMonitor()
    init(monitorNetwork: Bool = true) {
        guard monitorNetwork else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(isConnected: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "unieat.connectivity"))
    }
    func update(isConnected connected: Bool) {
        let reconnecting = !isConnected && connected
        isConnected = connected
        if reconnecting { serverUnreachable = false; onReconnect?() }
    }
    deinit { monitor.cancel() }
}
