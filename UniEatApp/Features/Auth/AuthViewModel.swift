import Combine
import Foundation
import UniEatCore

@MainActor
/// estado del login y registro que antes vivia en AuthView con @State
/// la pantalla solo dibuja y llama submit, la sesion la maneja SessionStore
final class AuthViewModel: FeatureViewModel {
    @Published var email = ""
    @Published var password = ""
    @Published var displayName = ""
    // true muestra el formulario de crear cuenta
    @Published var isRegistering = false
    // mientras se espera al server, desactiva el boton
    @Published var isSubmitting = false
    @Published var errorText: String?
    private let session: SessionStore
    init(session: SessionStore) { self.session = session; super.init(); observe(session) }
    /// aviso de la sesion, ej revisar el correo para confirmar
    var authMessage: String? { session.authMessage }
    /// entra o crea la cuenta, al registrarse primero valida nombre y contraseña en el celular
    /// cualquier error que no sea de auth se muestra como problema de conexion
    func submit() async {
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            if isRegistering {
                if let error = RegistrationRules.nameError(displayName) ?? RegistrationRules.passwordError(password) {
                    errorText = error
                    return
                }
                try await session.signUp(email: email, password: password, name: displayName)
            } else {
                try await session.signIn(email: email, password: password)
            }
        } catch {
            errorText = (error as? AuthFailure)?.localizedDescription ??
                "No se pudo conectar con el servicio. Inténtalo de nuevo."
        }
    }
}
