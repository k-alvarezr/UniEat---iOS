import SwiftUI
import UniEatCore

/// login y registro, corta el nombre y la contraseña mientras se escribe
/// y revisa las reglas antes de llamar al server
struct AuthView: View {
    // los campos y el envio del login viven en AuthViewModel
    @EnvironmentObject private var model: AuthViewModel

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
                    .font(.rounded(46, .black))
                Text("Tu almuerzo, mejor decidido.")
                    .font(.rounded(18, .semibold))

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Acceso", selection: $model.isRegistering) {
                            Text("Entrar").tag(false)
                            Text("Crear cuenta").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if model.isRegistering {
                            TextField("Nombre", text: $model.displayName)
                                .textContentType(.name)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: model.displayName) { _, value in
                                    model.displayName = String(value.prefix(RegistrationRules.maximumNameLength))
                                }
                            Text("Nombre: \(model.displayName.count)/15 caracteres")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Las cuentas nuevas empiezan como estudiante. Solicita un restaurante desde Perfil; un administrador debe aprobarlo.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        TextField("Correo", text: $model.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        SecureField("Contraseña", text: $model.password)
                            .textContentType(model.isRegistering ? .newPassword : .password)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.password) { _, value in
                                if model.isRegistering {
                                    model.password = String(value.prefix(RegistrationRules.maximumPasswordLength))
                                }
                            }
                        if model.isRegistering {
                            Text("Contraseña: 6–20 caracteres, con mayúscula, minúscula, número y carácter especial. \(model.password.count)/20")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = model.errorText ?? model.authMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Palette.coral)
                        }
                        SolidButton(title: model.isClosingSession ? "Cerrando sesión…" : (model.isSubmitting ? "Un momento…" : (model.isRegistering ? "Crear cuenta" : "Iniciar sesión")),
                                    icon: "arrow.right", color: Palette.yellow) {
                            Task { await model.submit() }
                        }
                        .disabled(!model.canUseNetwork || model.isSubmitting || model.isClosingSession || model.email.isEmpty || model.password.isEmpty ||
                                  (model.isRegistering && RegistrationRules.nameError(model.displayName) != nil))
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .background(Palette.cream)
        .connectionStatus(.authentication)
    }

}
