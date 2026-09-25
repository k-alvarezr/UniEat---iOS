import Foundation

struct AppConfiguration: Decodable {
    let supabaseURL: String
    let publishableKey: String

    static let current: AppConfiguration = {
        guard let url = Bundle.main.url(forResource: "BackendConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration(supabaseURL: "", publishableKey: "")
        }
        return config
    }()

    var isConfigured: Bool {
        URL(string: supabaseURL)?.scheme != nil && !publishableKey.isEmpty
    }
}
