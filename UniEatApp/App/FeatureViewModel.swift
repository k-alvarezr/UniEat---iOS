import Combine
import Foundation

/// papa de los viewmodels de cada pantalla
/// cuando cambia algo compartido (sesion, feed, red, reloj) avisa a la pantalla para que se redibuje,
/// asi cada viewmodel no tiene que copiar ese estado, solo lo lee de la fuente
@MainActor
class FeatureViewModel: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []   // suscripciones vivas mientras viva el viewmodel
    /// cada vez que object va a cambiar, este viewmodel tambien avisa que cambio
    func observe<T: ObservableObject>(_ object: T) {
        object.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}
