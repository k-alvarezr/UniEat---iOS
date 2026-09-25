import SwiftUI

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
    var cop: String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.groupingSeparator = "."
        number.maximumFractionDigits = 0
        return "$" + (number.string(from: NSNumber(value: self)) ?? "\(self)")
    }
}

struct BrandHeader: View {
    let title: String
    var subtitle = "Uniandes · En campus"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 16, weight: .heavy, design: .rounded))
                Text(subtitle).font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
        }
        .foregroundStyle(Palette.ink)
    }
}

struct Sticker: View {
    let text: String
    var color: Color = Palette.yellow
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(color, in: Capsule())
        .overlay(Capsule().stroke(Palette.ink, lineWidth: 1.4))
        .foregroundStyle(Palette.ink)
    }
}

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
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 15)
            .background(color, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 48)
    }
}

struct SurfaceCard<Content: View>: View {
    let content: Content

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

struct DemoNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
            Text("Modo demostración · contenido generado para probar la app")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cyan.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }
}
