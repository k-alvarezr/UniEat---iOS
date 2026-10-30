import SwiftUI

/// aviso de conexion compartido, cada vista pone su propio texto, no reemplaza lo que hace sin red:
/// cada pantalla sigue con su navegacion, copias, formularios o cola de envios
enum ConnectionContext {
    case authentication, today, filters, recommendation, saved, detail, reporting, waitTime
    case publishing, profile, administration, performance, gallery

    var guidance: String {
        switch self {
        case .authentication:
            "Puedes revisar el formulario. Iniciar sesión o crear una cuenta requiere conexión."
        case .today:
            "Puedes consultar los menús descargados y abrir su detalle. Su disponibilidad puede haber cambiado."
        case .filters:
            "Puedes ajustar los filtros y aplicarlos a los menús descargados, si tienes una copia disponible."
        case .recommendation:
            "Puedes elegir entre las opciones descargadas que cumplan tus filtros. La disponibilidad puede haber cambiado."
        case .saved:
            "Tus menús guardados siguen disponibles en este dispositivo. Su estado se comprobará al recuperar el servicio."
        case .detail:
            "Puedes consultar la copia, guardar el menú y preparar reportes. La vigencia y los cambios remotos no se pueden verificar."
        case .reporting, .waitTime:
            "Puedes completar el reporte. Los reportes guardados quedarán pendientes hasta recuperar el servicio."
        case .publishing:
            "Puedes editar tu borrador. Publicar, guardar cambios en el servidor o cerrar un menú requiere conexión."
        case .profile:
            "Puedes consultar tus datos y reportes pendientes. Enviar solicitudes o actualizar permisos requiere conexión."
        case .administration:
            "Las listas disponibles pueden estar desactualizadas. Aprobar locales o cambiar roles requiere conexión."
        case .performance:
            "Puedes consultar el último panel disponible para este período. Las cifras no se actualizan sin conexión."
        case .gallery:
            "Puedes navegar a las pantallas. Cada una indica qué información local y acciones están disponibles."
        }
    }
}

private struct ConnectionStatusModifier: ViewModifier {
    @EnvironmentObject private var connectivity: ConnectivityService
    let context: ConnectionContext

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let issue = connectivity.issue {
                VStack(alignment: .leading, spacing: 5) {
                    Label(issue.title, systemImage: issue == .noInternet ? "wifi.slash" : "exclamationmark.icloud")
                        .font(.subheadline.weight(.bold))
                    Text(context.guidance).font(.caption)
                    if issue == .serviceUnavailable {
                        Button(connectivity.isChecking ? "Comprobando…" : "Reintentar conexión") {
                            Task { await connectivity.retry() }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(connectivity.isChecking)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .foregroundStyle(Palette.ink)
                .background(Palette.yellow)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("connection-status")
            }
        }
    }
}

extension View {
    func connectionStatus(_ context: ConnectionContext) -> some View {
        modifier(ConnectionStatusModifier(context: context))
    }
}
