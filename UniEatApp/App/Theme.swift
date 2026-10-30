import SwiftUI

enum BrandFont {
    static let body = Font.custom("Quicksand-Light", size: 16, relativeTo: .body)

    static func text(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("Quicksand-Light", size: size).weight(weight)
    }
}

extension Font {
    /// letra redondeada para titulos y etiquetas, por defecto gruesa
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

enum Palette {
    static let yellow = Color(red: 1, green: 0.898, blue: 0)
    static let cyan = Color(red: 0.098, green: 0.827, blue: 0.91)
    static let green = Color(red: 0.545, green: 0.878, blue: 0)
    static let coral = Color(red: 1, green: 0.353, blue: 0.212)
    static let ink = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let cream = Color(red: 0.961, green: 0.941, blue: 0.902)
    static let paper = Color.white
}

extension Int {
    // un solo formatter para todos los precios, crearlo en cada llamada es lento
    private static let copFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = SpanishPresentation.locale
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// precio en pesos, 14500 -> $14.500
    var cop: String {
        "$" + (Int.copFormatter.string(from: NSNumber(value: self)) ?? "\(self)")
    }
}

/// cabecera de cada pantalla: logo, titulo y boton para ir a perfil
struct BrandHeader: View {
    @EnvironmentObject private var store: AppContainer
    let title: String
    var subtitle = "Uniandes · En campus"
    // en perfil y en las hojas (como reportar) no tiene sentido el boton de perfil
    var showsProfileButton = true

    var body: some View {
        HStack(spacing: 9) {
            logo
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BrandFont.text(16, weight: .bold))
                Text(subtitle).font(BrandFont.text(10)).foregroundStyle(.secondary)
            }
            Spacer()
            if showsProfileButton {
                Button { store.selectedTab = .profile } label: {
                    Image(systemName: "person.crop.circle.fill").font(.title2)
                }
                .accessibilityLabel("Ir a mi perfil")
            }
        }
        .foregroundStyle(Palette.ink)
    }

    // el rayo de la marca en un cuadrito negro
    private var logo: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// etiqueta chica con borde, para zona, precio, estado, etc
struct Sticker: View {
    let text: String
    var color: Color = Palette.yellow
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(BrandFont.text(11, weight: .bold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color, in: Capsule())
        .overlay(Capsule().stroke(Palette.ink, lineWidth: 1.4))
        .foregroundStyle(Palette.ink)
    }
}

/// boton grande de la marca, de todo el ancho y minimo 48 de alto para tocarlo facil
struct SolidButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = Palette.coral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title)
                if let icon { Image(systemName: icon) }
                Spacer()
            }
            .font(BrandFont.text(16, weight: .bold))
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 15)
            .background(color, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 48)
    }
}

/// tarjeta blanca con borde negro, recibe cualquier contenido adentro
struct SurfaceCard<Content: View>: View {
    let content: Content

    // @ViewBuilder deja escribir SurfaceCard { ... } con varias vistas adentro
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 2))
    }
}
