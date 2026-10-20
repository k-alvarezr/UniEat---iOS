import SwiftUI
import UniEatCore

/// hoja para reportar un cambio sobre la version del menu que se esta viendo
/// el reporte nunca cambia el menu oficial
struct ReportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let menu: DailyMenu
    @State private var kind: ReportKind
    @State private var note = ""
    @State private var waitMinutes = 20
    @State private var confirmationMessage: String?
    @State private var errorText: String?
    @State private var isSending = false

    init(menu: DailyMenu, initialKind: ReportKind = .unavailable) {
        self.menu = menu
        _kind = State(initialValue: initialKind)
    }

    private let choices: [(kind: ReportKind, title: String, icon: String)] = [
        (.unavailable, "Plato agotado o no disponible", "fork.knife"),
        (.price, "Precio distinto al publicado", "tag"),
        (.longLine, "Fila mucho más larga", "person.3"),
        (.location, "Ubicación difícil de encontrar", "mappin.slash"),
        (.accurate, "El menú sigue correcto", "checkmark.seal"),
        (.arrival, "Llegué al local", "figure.walk"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    BrandHeader(title: "Reportar un cambio")
                    Text("\(menu.establishmentName) · versión \(menu.version) del menú").font(.subheadline)
                    if let confirmationMessage {
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
            Button { kind = choice.kind } label: {
                HStack(spacing: 10) {
                    Image(systemName: choice.icon).frame(width: 26)
                    Text(choice.title)
                    Spacer()
                    Image(systemName: kind == choice.kind ? "checkmark.circle.fill" : "circle")
                }
                .font(.rounded(14, .bold))
                .padding(13)
                .background(kind == choice.kind ? Palette.yellow : Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
                .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
        }
        if kind == .longLine {
            Stepper("Tiempo observado: \(waitMinutes) min", value: $waitMinutes, in: 0...120, step: 5)
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
        TextField("Comentario opcional", text: $note, axis: .vertical)
            .lineLimit(3...5)
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        Text(kind.isDiscrepancy
             ? "Tu reporte no modifica el menú oficial. Otros usuarios verán una advertencia mientras se revisa."
             : "Tu observación ayuda a informar a la comunidad y no modifica el menú oficial.")
            .font(.footnote).foregroundStyle(.secondary)
        if let errorText {
            Text(errorText).font(.footnote.weight(.semibold)).foregroundStyle(Palette.coral)
        }
        SolidButton(title: isSending ? "Enviando…" : "Enviar reporte comunitario",
                    icon: "paperplane.fill", color: Palette.coral) {
            Task { await send() }
        }
        .disabled(isSending)
    }

    /// solo dice gracias si el server acepto, si falla muestra por que
    /// tipo sin internet o muchos reportes y deja lo escrito para intentar otra vez
    private func send() async {
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            let status = try await store.submitReport(for: menu, kind: kind, note: note,
                                                      waitMinutes: kind == .longLine ? waitMinutes : nil)
            confirmationMessage = switch status {
            case "pending": "Gracias. Tu reporte quedó pendiente de revisión."
            case "confirmed": "Gracias. Otros estudiantes reportaron lo mismo: el cambio quedó confirmado."
            default: "Gracias. Tu observación quedó registrada."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
