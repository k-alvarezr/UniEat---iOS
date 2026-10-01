import Foundation

/// Reglas de alta de cuenta. Se validan antes de llamar a Supabase y también en el formulario.
public enum RegistrationRules {
    public static let maximumNameLength = 15
    public static let maximumPasswordLength = 20

    public static func nameError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Escribe tu nombre." }
        if trimmed.count > maximumNameLength { return "El nombre admite máximo 15 caracteres." }
        return nil
    }

    public static func passwordError(_ password: String) -> String? {
        if password.count > maximumPasswordLength { return "La contraseña admite máximo 20 caracteres." }
        if password.count < 6 { return "La contraseña debe tener al menos 6 caracteres." }
        if !password.contains(where: { $0.isUppercase }) { return "Incluye al menos una mayúscula." }
        if !password.contains(where: { $0.isLowercase }) { return "Incluye al menos una minúscula." }
        if !password.contains(where: { $0.isNumber }) { return "Incluye al menos un número." }
        if !password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            return "Incluye al menos un carácter especial."
        }
        return nil
    }
}
