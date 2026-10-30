import Combine
import Foundation
import UniEatCore

@MainActor
final class AuthViewModel: FeatureViewModel {
    @Published var email = ""
    @Published var password = ""
    @Published var displayName = ""
    @Published var isRegistering = false
    @Published var isSubmitting = false
    @Published var errorText: String?
    private let session: SessionStore
    init(session: SessionStore) { self.session = session; super.init(); observe(session) }
    var authMessage: String? { session.authMessage }
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
