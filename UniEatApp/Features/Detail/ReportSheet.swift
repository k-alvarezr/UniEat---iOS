import SwiftUI
import UniEatCore

struct ReportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let menu: DailyMenu
    @State private var kind: ReportKind = .unavailable
    @State private var note = ""
    @State private var waitMinutes = 20
    @State private var sent = false

    init(menu: DailyMenu, initialKind: ReportKind = .unavailable) {
        self.menu = menu
        _kind = State(initialValue: initialKind)
    }

    private let choices: [(ReportKind, String, String)] = [
        (.unavailable, "Plato agotado o no disponible", "fork.knife"),
        (.price, "Precio distinto al publicado", "tag"),
        (.longLine, "Fila mucho más larga", "person.3"),
        (.location, "Ubicación difícil de encontrar", "mappin.slash"),
        (.accurate, "El menú sigue correcto", "checkmark.seal"),
        (.arrival, "Llegué al local", "figure.walk")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    BrandHeader(title: "Reportar un cambio")
                    Text("\(menu.establishmentName) · versión \(menu.version) del menú")
                        .font(.subheadline)
                    if sent {
                        SurfaceCard {
                            Label("Gracias. Tu reporte quedó pendiente de verificación.", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                        }
                    } else {
                        ForEach(choices.indices, id: \.self) { index in
                            let choice = choices[index]
                            Button {
                                kind = choice.0
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: choice.2).frame(width: 26)
                                    Text(choice.1)
                                    Spacer()
                                    Image(systemName: kind == choice.0 ? "checkmark.circle.fill" : "circle")
                                }
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .padding(13)
                                .background(kind == choice.0 ? Palette.yellow : Palette.paper,
                                            in: RoundedRectangle(cornerRadius: 12))
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
                        Text("Tu reporte no modifica el menú oficial automáticamente. Otros usuarios verán una advertencia mientras se verifica.")
                            .font(.footnote).foregroundStyle(.secondary)
                        SolidButton(title: "Enviar reporte comunitario", icon: "paperplane.fill", color: Palette.coral) {
                            store.submitReport(for: menu, kind: kind, note: note,
                                               waitMinutes: kind == .longLine ? waitMinutes : nil)
                            sent = true
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.cream)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } } }
        }
    }
}
