import SwiftUI
import UniEatCore

struct InsufficientQueueEvidenceView: View {
    @State private var showingReport = false
    let menu: DailyMenu

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "Fila de espera")
                DemoNotice()
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Sticker(text: "SIN PROYECCIÓN", color: Palette.cyan, icon: "hourglass")
                        Text(menu.establishmentName)
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                        Label(menu.address.isEmpty ? menu.area : menu.address, systemImage: "mappin")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Información insuficiente", systemImage: "hourglass")
                            .font(.system(size: 21, weight: .heavy, design: .rounded))
                        Text("\(menu.waitSampleCount) reporte(s) elegible(s)")
                            .font(.subheadline)
                        if let newest = menu.waitNewestReportAt {
                            Text("Último reporte: \(SpanishPresentation.dateAndTime(newest))")
                                .font(.caption)
                        }
                        Text("Mostramos un tiempo aproximado solo cuando hay al menos tres reportes recientes. No inventamos una estimación cuando faltan datos.")
                            .font(.subheadline)
                            .padding(10)
                            .background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "figure.walk").font(.title2)
                            Text("Zona \(menu.area)").font(.headline)
                            Text("Consulta la ubicación antes de salir.").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "person.3").font(.title2)
                            Text("Comunidad").font(.headline)
                            Text("Tu reporte queda pendiente de verificación.").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("¿Ya estás en la fila?")
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                    Text("Ayuda a otras personas con el tiempo que observas ahora.")
                        .font(.subheadline)
                    SolidButton(title: "Reportar fila actual", icon: "arrow.right", color: Palette.yellow) {
                        showingReport = true
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.coral, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 2))
                Text("Menú publicado")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                ForEach(menu.items) { dish in
                    SurfaceCard {
                        HStack {
                            Text(dish.name).font(.headline)
                            Spacer()
                            Sticker(text: dish.priceCop.cop, color: Palette.yellow)
                        }
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Ubicación y pago").font(.headline)
                        Text(menu.address.isEmpty ? "Dirección no confirmada" : menu.address)
                        Text(menu.paymentMethods.isEmpty ? "Pago no declarado" : menu.paymentMethods.joined(separator: " · "))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationTitle("Sin estimación de fila")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReport) { ReportSheet(menu: menu, initialKind: .longLine) }
    }
}
