import SwiftUI
import UniEatCore

/// tarjeta para decir cuanta fila hay, va despues de llegar al local y en la pantalla de espera
/// la fila es un dato normal, no una irregularidad, con 3 reportes recientes de distintas personas
/// el server estima el tiempo para los demas, si la misma persona reporta otra vez se usa el ultimo
struct WaitTimeCard: View {
    @EnvironmentObject private var app: AppContainer
    let menu: DailyMenu
    var onSent: () async -> Void = {}
    var body: some View { WaitTimeScreen(model: app.makeReport(menu, kind: .longLine, waitObservation: true), onSent: onSent) }
}

private struct WaitTimeScreen: View {
    @StateObject var model: ReportViewModel
    // para que la pantalla que la usa recargue y muestre la estimacion nueva
    var onSent: () async -> Void = {}

    // el viewmodel se crea una sola vez, igual que en el detalle
    init(model: @autoclosure @escaping () -> ReportViewModel, onSent: @escaping () async -> Void = {}) {
        _model = StateObject(wrappedValue: model())
        self.onSent = onSent
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("¿Cuánta fila hay?", systemImage: "person.3").font(.headline)
                Stepper("\(model.minutes) min de espera", value: $model.minutes, in: 0...120, step: 5)
                if let confirmation = model.confirmationMessage {
                    Text(confirmation)
                        .font(.caption.weight(.semibold))
                }
                if let errorText = model.errorText {
                    Text(errorText).font(.caption.weight(.semibold)).foregroundStyle(Palette.coral)
                }
                // se puede volver a mandar si la fila cambio, el server se queda con el ultimo
                SolidButton(title: model.isSending ? "Enviando…" : (model.confirmationMessage == nil ? "Enviar tiempo de fila" : "Actualizar tiempo de fila"),
                            icon: "paperplane.fill", color: Palette.yellow) {
                    Task { await send() }
                }
                .disabled(model.isSending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // manda la fila como observacion con los minutos, no cambia el menu ni genera aviso
    private func send() async {
        await model.send()
        if model.confirmationMessage != nil { await onSent() }
    }
}
