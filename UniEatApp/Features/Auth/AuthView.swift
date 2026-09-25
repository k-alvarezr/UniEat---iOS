import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var role = "student"
    @State private var isRegistering = false
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Spacer(minLength: 42)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 35, weight: .black))
                    .frame(width: 68, height: 68)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 3))
                Text("UniEat")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                Text("Tu almuerzo, mejor decidido.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                DemoNotice()

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Acceso", selection: $isRegistering) {
                            Text("Entrar").tag(false)
                            Text("Crear cuenta").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if isRegistering {
                            TextField("Nombre", text: $displayName)
                                .textContentType(.name)
                                .textFieldStyle(.roundedBorder)
                            Picker("Tipo de cuenta", selection: $role) {
                                Text("Estudiante").tag("student")
                                Text("Restaurante").tag("restaurant")
                            }
                            .pickerStyle(.segmented)
                        }
                        TextField("Correo", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        SecureField("Contraseña", text: $password)
                            .textContentType(isRegistering ? .newPassword : .password)
                            .textFieldStyle(.roundedBorder)
                        if let message = errorText ?? store.authMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Palette.coral)
                        }
                        SolidButton(title: isSubmitting ? "Un momento…" : (isRegistering ? "Crear cuenta" : "Iniciar sesión"),
                                    icon: "arrow.right", color: Palette.yellow) {
                            Task { await submit() }
                        }
                        .disabled(isSubmitting || email.isEmpty || password.isEmpty)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Probar sin backend")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                    HStack(spacing: 10) {
                        Button("Soy estudiante") { store.enterDemo(role: "student") }
                            .buttonStyle(DemoChoiceStyle(color: Palette.cyan))
                        Button("Soy restaurante") { store.enterDemo(role: "restaurant") }
                            .buttonStyle(DemoChoiceStyle(color: Palette.green))
                    }
                    Text("El modo demo usa datos locales y no crea una cuenta real.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .background(Palette.cream)
    }

    private func submit() async {
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            if isRegistering {
                try await store.signUp(email: email, password: password, name: displayName, role: role)
            } else {
                try await store.signIn(email: email, password: password)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct DemoChoiceStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
