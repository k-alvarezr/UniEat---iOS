import SwiftUI
import UniEatCore

/// hoja para reportar algo raro sobre la version del menu que se esta viendo
/// el reporte nunca cambia el menu oficial
/// la fila y la llegada no van aca, estan en el detalle porque son datos normales y no irregularidades
struct ReportSheet: View {
    @EnvironmentObject private var app: AppStore
    let menu: DailyMenu
    var initialKind: ReportKind = .unavailable
    // se crea el viewmodel de la hoja con AppStore y lo usa la pantalla de adentro
    var body: some View { ReportScreen(menu: menu, model: app.makeReport(menu, kind: initialKind)) }
}

private struct ReportScreen: View {
    @StateObject private var model: ReportViewModel
    @Environment(\.dismiss) private var dismiss
    let menu: DailyMenu

    init(menu: DailyMenu, model: ReportViewModel) {
        self.menu = menu
        _model = StateObject(wrappedValue: model)
    }

    private let choices: [(kind: ReportKind, title: String, icon: String)] = [
        (.unavailable, "Plato agotado o no disponible", "fork.knife"),
        (.price, "Precio distinto al publicado", "tag"),
        (.location, "Ubicación difícil de encontrar", "mappin.slash"),
        (.accurate, "El menú sigue correcto", "checkmark.seal"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    BrandHeader(title: "Reportar un cambio", showsProfileButton: false)
                    Text("\(menu.establishmentName) · versión \(menu.version) del menú").font(.subheadline)
                    if let confirmationMessage = model.confirmationMessage {
                        SurfaceCard {
                            Label(confirmationMessage, systemImage: "checkmark.circle.fill").font(.headline)
                        }
                    } else {
                        form
                    }
                }
                .padding(16)
            }
            .background(Palette.cream)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } } }
        }
    }

    @ViewBuilder private var form: some View {
        ForEach(choices, id: \.kind) { choice in
            Button { model.kind = choice.kind } label: {
                HStack(spacing: 10) {
                    Image(systemName: choice.icon).frame(width: 26)
                    Text(choice.title)
                    Spacer()
                    Image(systemName: model.kind == choice.kind ? "checkmark.circle.fill" : "circle")
                }
                .font(.rounded(14, .bold))
                .padding(13)
                .background(model.kind == choice.kind ? Palette.yellow : Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
                .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
        }
        TextField("Comentario opcional", text: $model.note, axis: .vertical)
            .lineLimit(3...5)
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        Text(model.kind.isDiscrepancy
             ? "Tu reporte no modifica el menú oficial. Otros usuarios verán una advertencia mientras se revisa."
             : "Tu observación ayuda a informar a la comunidad y no modifica el menú oficial.")
            .font(.footnote).foregroundStyle(.secondary)
        if let errorText = model.errorText {
            Text(errorText).font(.footnote.weight(.semibold)).foregroundStyle(Palette.coral)
        }
        SolidButton(title: model.isSending ? "Enviando…" : "Enviar reporte comunitario",
                    icon: "paperplane.fill", color: Palette.coral) {
            Task { await send() }
        }
        .disabled(model.isSending)
    }

    /// solo dice gracias si el server acepto, si falla muestra por que
    /// tipo sin internet o muchos reportes y deja lo escrito para intentar otra vez
    private func send() async { await model.send() }
}

/// tarjeta para decir cuanta fila hay, va despues de llegar al local y en la pantalla de espera
/// la fila es un dato normal, no una irregularidad, con 3 reportes recientes de distintas personas
/// el server estima el tiempo para los demas, si la misma persona reporta otra vez se usa el ultimo
struct WaitTimeCard: View {
    @EnvironmentObject private var app: AppStore
    let menu: DailyMenu
    var onSent: () async -> Void = {}
    // la tarjeta de fila tambien manda por ReportViewModel, como un reporte de fila larga
    var body: some View { WaitTimeScreen(model: app.makeReport(menu, kind: .longLine), onSent: onSent) }
}

private struct WaitTimeScreen: View {
    @StateObject var model: ReportViewModel
    // para que la pantalla que la usa recargue y muestre la estimacion nueva
    var onSent: () async -> Void = {}

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
