import SwiftUI
import UniEatCore

/// hoja para reportar algo raro sobre la version del menu que se esta viendo
/// el reporte nunca cambia el menu oficial
/// la fila y la llegada no van aca, estan en el detalle porque son datos normales y no irregularidades
struct ReportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let menu: DailyMenu
    @State private var kind: ReportKind
    @State private var note = ""
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
        (.location, "Ubicación difícil de encontrar", "mappin.slash"),
        (.accurate, "El menú sigue correcto", "checkmark.seal"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    BrandHeader(title: "Reportar un cambio", showsProfileButton: false)
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
            let status = try await store.submitReport(for: menu, kind: kind, note: note, waitMinutes: nil)
            confirmationMessage = switch status {
            case "pending": "Gracias. Tu reporte quedó pendiente de revisión."
            case "confirmed": "Gracias. Otros estudiantes reportaron lo mismo: el cambio quedó confirmado."
            case "queued": "Sin conexión. Tu reporte quedó guardado y se enviará cuando vuelva la conexión."
            default: "Gracias. Tu observación quedó registrada."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// tarjeta para decir cuanta fila hay, va despues de llegar al local y en la pantalla de espera
/// la fila es un dato normal, no una irregularidad, con 3 reportes recientes de distintas personas
/// el server estima el tiempo para los demas, si la misma persona reporta otra vez se usa el ultimo
struct WaitTimeCard: View {
    @EnvironmentObject private var store: AppStore
    let menu: DailyMenu
    // para que la pantalla que la usa recargue y muestre la estimacion nueva
    var onSent: () async -> Void = {}
    @State private var minutes = 15
    @State private var sentMinutes: Int?
    @State private var errorText: String?
    @State private var isSending = false

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("¿Cuánta fila hay?", systemImage: "person.3").font(.headline)
                Stepper("\(minutes) min de espera", value: $minutes, in: 0...120, step: 5)
                if let sentMinutes {
                    Text("Gracias, reportaste \(sentMinutes) min. Con esto se estima la fila para los demás.")
                        .font(.caption.weight(.semibold))
                }
                if let errorText {
                    Text(errorText).font(.caption.weight(.semibold)).foregroundStyle(Palette.coral)
                }
                // se puede volver a mandar si la fila cambio, el server se queda con el ultimo
                SolidButton(title: isSending ? "Enviando…" : (sentMinutes == nil ? "Enviar tiempo de fila" : "Actualizar tiempo de fila"),
                            icon: "paperplane.fill", color: Palette.yellow) {
                    Task { await send() }
                }
                .disabled(isSending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // manda la fila como observacion con los minutos, no cambia el menu ni genera aviso
    private func send() async {
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            _ = try await store.submitReport(for: menu, kind: .longLine, note: "", waitMinutes: minutes)
            sentMinutes = minutes
            await onSent()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
