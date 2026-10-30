import Combine
import Foundation
import Network

/// el estado de la red sale del AppStore viejo a su propio servicio
/// isConnected lo da NWPathMonitor (el celular tiene red), serverUnreachable lo pone el feed
/// cuando hay red pero el server no responde
@MainActor
final class ConnectivityService: ObservableObject {
    @Published private(set) var isConnected = true   // el celular tiene internet
    @Published var serverUnreachable = false         // hay internet pero el server no responde
    /// sin internet o con el server caido
    var isOffline: Bool { !isConnected || serverUnreachable }
    /// NWPathMonitor solo confirma una ruta de red; no garantiza que UniEat responda.
    var issue: ConnectionIssue? {
        if !isConnected { return .noInternet }
        return serverUnreachable ? .serviceUnavailable : nil
    }
    @Published private(set) var isChecking = false
    var checkService: (() async throws -> Void)?
    var onReconnect: (() -> Void)?                    // lo pone AppStore para mandar las colas al volver la red
    private let monitor = NWPathMonitor()             // avisa cuando cambia la conexion
    /// monitorNetwork en false es para las pruebas, asi no depende de la red real
    init(monitorNetwork: Bool = true) {
        guard monitorNetwork else { return }
        // cada cambio de red llega en un hilo aparte y se pasa al hilo de la pantalla
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(isConnected: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "unieat.connectivity"))
    }
    /// si estaba sin red y vuelve, se limpia lo del server caido y se avisa para mandar las colas
    func update(isConnected connected: Bool) {
        // el monitor avisa varias veces aunque la red no cambie, sin este guard cada aviso redibuja las pantallas
        guard connected != isConnected else { return }
        let reconnecting = !isConnected && connected
        isConnected = connected
        if reconnecting {
            serverUnreachable = false
            onReconnect?()
        }
    }
    /// Todas las rutas de la API informan el resultado, no solo el feed.
    func serviceResponded(_ available: Bool) {
        guard serverUnreachable == available else { return }
        serverUnreachable = !available
    }
    /// Una comprobación pública y sin credenciales permite recuperarse incluso desde login.
    /// Se comparte una sola comprobación entre todas las pantallas.
    func retry() async {
        guard isConnected, !isChecking, let checkService else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            try await checkService()
            serviceResponded(true)
        } catch is CancellationError { }
        catch { serviceResponded(false) }
    }
    deinit { monitor.cancel() }
}

enum ConnectionIssue: Equatable {
    case noInternet, serviceUnavailable
    var title: String {
        switch self {
        case .noInternet: "Sin conexión a internet"
        case .serviceUnavailable: "No podemos conectar con UniEat"
        }
    }
}
