import SwiftUI
import UniEatCore

/// hoja para reportar algo raro sobre la version del menu que se esta viendo
/// el reporte nunca cambia el menu oficial
/// quejarse de la fila es distinto a anotar minutos o confirmar llegada en el detalle
struct ReportSheet: View {
    @EnvironmentObject private var app: AppContainer
    let menu: DailyMenu
    var initialKind: ReportKind = .unavailable
    // se crea el viewmodel de la hoja con AppContainer y lo usa la pantalla de adentro
    var body: some View { ReportScreen(menu: menu, model: app.makeReport(menu, kind: initialKind)) }
}

private struct ReportScreen: View {
    @StateObject private var model: ReportViewModel
    @Environment(\.dismiss) private var dismiss
    let menu: DailyMenu

    // el viewmodel se crea una sola vez, igual que en el detalle
    init(menu: DailyMenu, model: @autoclosure @escaping () -> ReportViewModel) {
        self.menu = menu
        _model = StateObject(wrappedValue: model())
    }

    private let choices: [(kind: ReportKind, title: String, icon: String)] = [
        (.unavailable, "Plato agotado o no disponible", "fork.knife"),
        (.price, "Precio distinto al publicado", "tag"),
        (.location, "Ubicación difícil de encontrar", "mappin.slash"),
        (.longLine, "La fila fue demasiado larga", "person.3"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    BrandHeader(title: "Reportar un cambio")
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
            .connectionStatus(.reporting)
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
