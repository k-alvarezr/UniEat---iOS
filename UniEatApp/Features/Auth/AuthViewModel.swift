import Combine
import Foundation
import UniEatCore

/// estado del login y registro que antes vivia en AuthView con @State
/// la pantalla solo dibuja y llama submit, la sesion la maneja SessionStore
@MainActor
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
    private let connectivity: ConnectivityService
    init(session: SessionStore, connectivity: ConnectivityService) {
        self.session = session
        self.connectivity = connectivity
        super.init()
        observe(session)
        observe(connectivity)
    }
    /// aviso de la sesion, ej revisar el correo para confirmar
    var authMessage: String? { session.authMessage }
    var isClosingSession: Bool { session.isForgetting }
    var canUseNetwork: Bool { !connectivity.isOffline }
    /// al cambiar de cuenta se borra la contraseña escrita y cualquier error
    func reset() {
        password = ""
        errorText = nil
        isSubmitting = false
    }
    /// entra o crea la cuenta, al registrarse primero valida nombre y contraseña en el celular
    /// cada tipo de error tiene su mensaje, asi se sabe si es la red, el server o la cuenta
    func submit() async {
        guard !isSubmitting, !session.isForgetting else { return }
        guard canUseNetwork else {
            errorText = "Iniciar sesión o crear una cuenta requiere conexión. Puedes conservar el formulario y reintentar."
            return
        }
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
        } catch is CancellationError {
            // otro inicio o cierre de sesion le gano a este, no hay nada que mostrar
        } catch let failure as AuthFailure {
            errorText = failure.localizedDescription
        } catch let failure as APIFailure {
            errorText = failure.message
        } catch let error as URLError {
            guard !Task.isCancelled, error.code != .cancelled else { return }
            connectivity.serviceResponded(false)
            errorText = connectivity.isConnected
                ? "No pudimos contactar al servicio de acceso. Reintenta cuando esté disponible."
                : "Sin conexión. Revisa tu internet e inténtalo de nuevo."
        } catch {
            errorText = "El servicio respondió algo inesperado. Inténtalo de nuevo."
        }
    }
}
