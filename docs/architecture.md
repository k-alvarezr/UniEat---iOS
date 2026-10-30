# Arquitectura actual de UniEat iOS

Esta estructura parte de los PR #40 y #41 de Juan Esteban: conserva sus modelos SwiftData,
archivos de detalle y borrador, lecturas en segundo plano y operaciones concurrentes.
La preparación distribuye esas responsabilidades por funcionalidad y corrige sus límites
de sesión y sincronización. El backend sigue siendo la autoridad de permisos, versiones y ranking.

## Componentes y comunicación

```mermaid
flowchart TD
    Root[AppStore: composición y pestaña] --> VM[ViewModels por funcionalidad]
    V[Views SwiftUI] --> VM
    VM --> Session[SessionStore: identidad y permisos]
    VM --> Feed[FeedViewModel: resultado y filtros compartidos]
    VM --> Domain[UniEatCore: entidades y decisiones]
    VM --> Services[Servicios de detalle, publicación, cuenta y eventos]
    VM --> Facade[ReportingFacade]
    Services --> API[APIRequesting / APIClient]
    Services --> Files[FileStore]
    VM --> Content[LocalContentService / ModelActor]
    Content --> SwiftData
    Facade --> API
    Facade --> DB[ReportOutbox / LocalDatabase]
    DB --> SwiftData[ModelContainer único]
    API --> Back[api-v1 / PostgreSQL / Supabase Auth]
```

**Razón:** cada ViewModel concentra el estado y las acciones de su pantalla; los servicios
coordinan operaciones de datos. Las entidades se comparten entre pantallas. La sesión,
el feed aplicado, la cola y el contenedor tienen un único propietario para impedir estados divergentes.

| Pantalla o flujo | Estado y acciones | Dependencias principales |
|---|---|---|
| Acceso / registro | `AuthViewModel` | `SessionStore` |
| Hoy / copia del feed | `FeedViewModel` | API, reloj, conectividad, eventos |
| Filtros | `FiltersViewModel` | Feed compartido; el servicio de ubicación sigue leyendo GPS |
| Elige por mí | `RecommendationViewModel` | Mismo feed y filtros; conserva el orden del servidor |
| Detalle | `MenuDetailViewModel`, creado por publicación | `MenuDetailService`, guardados, eventos, reloj |
| Reporte / observación de fila | `ReportViewModel`, creado por formulario | `ReportingFacade` |
| Publicar / editar / cerrar | `PublishViewModel` | `PublishingService`, sesión, feed y reloj |
| Rendimiento / mis métricas | `PerformanceViewModel` | API, sesión, eventos |
| Perfil | `ProfileViewModel` | Sesión, guardados y estado de la cola |
| Solicitud de establecimiento | `EstablishmentViewModel` | `AccountService`, sesión y geocodificación |
| Aprobaciones / roles | `AdminApprovalsViewModel`, `AdminRolesViewModel` | `AccountService` y sesión |
| Guardados | `SavedMenusViewModel` | `LocalContentService`, SwiftData y eventos; migración del formato anterior |
| Piloto BQ-08 | `WaitIndicatorPilot` | Sesión, API de asignación y metadata de eventos |

`AppStore` es el punto de composición e inyección y conserva la pestaña seleccionada.
No es el ViewModel de todas las pantallas. `UniEatApp` inyecta los objetos compartidos;
los formularios de reporte y el detalle crean instancias de presentación propias mediante fábricas.
Una tarjeta o una etiqueta que solo renderiza información no necesita ViewModel propio.

## Modelos

`Packages/UniEatCore/Sources/UniEatCore/` contiene un archivo por entidad:
`DailyMenu`, `MenuDish`, `FeedFilters`, `Profile`, `ReportKind`, `PerformanceSummary`,
`PerformanceRates` y `UniEatDates`, además de las decisiones de vigencia y ubicación.
Se conserva el API público y el formato Codable que consumen las pantallas y las pruebas existentes.
`MenuDetail` representa la respuesta de vigencia/versiones/reportes y sirve a todo el flujo de detalle.

Los DTO del transporte permanecen en `Data/APIClient.swift`. `PublishDraft` y `DishDraft`
están junto a su ViewModel, porque representan el formulario. `MenuSnapshot` y `PendingReport`
permanecen en `Data/LocalDatabase.swift` como modelos de persistencia de Juan. La base local es
relacional y usa el mismo `ModelContainer`; la separación de entidades del dominio no crea nuevas bases.

Sprint 3 añade `SavedMenu`, `SavedDish` y `FeedCacheRecord` en `LocalContentModels.swift`.
`LocalContentService` crea `LocalContentStore` fuera de MainActor, con contexto propio sobre ese contenedor.
`SavedMenuEntry` es el valor Codable/Sendable de presentación y migración; los objetos SwiftData no cruzan
actores. `FeedMemoryCache` y `FeedImageStore` tienen políticas explícitas descritas en [sprint3.md](sprint3.md).

## Patrones y responsabilidades

- **MVVM, arquitectónico:** las vistas dibujan y envían acciones. Los ViewModels exponen estado
  observable y acciones de presentación. `UniEatCore` y los servicios contienen decisiones/datos.
- **Facade, diseño:** `ReportingFacade` ofrece `submitReport` y `flushReports`, coordinando sesión,
  almacenamiento, API y confirmación sin exponer ese protocolo a los formularios. Su ámbito son reportes.
- **Observer, diseño:** `ObservableObject`, `@Published` y las suscripciones de `FeatureViewModel`
  propagan cambios de las fuentes compartidas sin duplicar sus datos.
- **Transporte tipado e inyección:** `APIRequesting`, `SessionAuthenticating` y `ReportOutbox`
  permiten probar comportamiento sin red real. La inyección es una técnica de composición;
  no se contabiliza como un patrón GoF adicional.
- **Strategy en backend:** `rank-v1` sigue calculándose en el servidor. La recomendación conserva
  ese resultado; no se restaura la estrategia de la demo eliminada.

Juan conserva la autoría de la base de almacenamiento y de las estrategias de concurrencia.
La preparación de Kevin reorganiza esas implementaciones y añade límites, políticas de reintento,
pruebas y documentación. La funcionalidad pendiente de cada integrante sigue en sus issues originales.

## Concurrencia preservada y límites

- `SessionStore.refreshAccount` usa `async let` para pedir cuenta y establecimientos en paralelo.
  Comprueba usuario y generación de sesión antes de aplicar los dos resultados.
- `MenuDetailService.cached` lee y decodifica archivos con `Task.detached(priority: .utility)`.
  Devuelve valores `Sendable`; el reloj y la presentación se actualizan en `MainActor`.
- `MenuDetailViewModel.load` inicia copia y red con `async let`. La copia puede mostrarse mientras
  llega la respuesta. Las tareas pertenecen al `task` de la vista; la cancelación no se presenta como desconexión.
- `PublishingService.loadDraft` conserva la lectura `detached` de Juan; el ViewModel comprueba
  que el formulario no se haya editado mientras se leía, antes de restaurarlo.
- `ReportingFacade.flushReports` toma snapshots de valor y usa `withTaskGroup` con prioridad
  utility y hasta cuatro solicitudes simultáneas. Los objetos SwiftData y sus eliminaciones permanecen
  en `MainActor`. Un error temporal detiene la incorporación de más solicitudes al grupo.

La concurrencia no equivale a hacer trabajo pesado en la UI: las esperas de red suspenden tareas;
el trabajo de lectura/decodificación de archivos se ejecuta fuera del actor principal.
El tamaño máximo del grupo limita presión de red y cuotas sin perder las filas que faltan por enviar.

El feed mantiene identidad de filas y fuente/filtros del snapshot aplicado. La exposición BQ-08 tiene
su propia clave contextual (sesión, asignación, versión, fuente y evidencia) para registrar copia → vivo
sin destruir las tarjetas. `FeedImageStore` comparte solicitudes por URL entre el grupo de cuatro hijos y
las vistas, con un solo caché/procesador Kingfisher. Cancelar una precarga no cancela un consumidor que
todavía necesita la foto. La migración conserva las imágenes antiguas hasta confirmar el nuevo archivo.

## Sesión, vigencia y sincronización

Cada petición captura una generación de autenticación; si cambia durante la obtención del token
o la respuesta, su resultado se cancela. Al cerrar sesión se cancela la renovación pendiente para
impedir que escriba otra vez en Keychain. Las respuestas de feed comprueban también identificador
de solicitud, usuario y filtros: una solicitud vieja con filtros idénticos tampoco pisa la última.

`ServerClock` conserva una referencia del servidor y avanza con `systemUptime` durante el proceso:
cambiar manualmente la hora del teléfono no cambia vigencia, evidencia de fila ni hora de observación.
Las copias de feed/detalle guardan una referencia para el relanzamiento offline. En esa apertura la
estimación del tiempo transcurrido depende del reloj local; se identifica la copia y se resincroniza
al recibir red. Una referencia guardada nunca reemplaza una hora en vivo. Se mantiene la mejora de Juan:
el reloj no publica cambios ni provoca redibujos de toda la aplicación.

Los reportes se guardan antes de enviarse. Su UUID es estable y se envía como `clientReportId`;
`observedAt` conserva la observación original. Solo una respuesta aceptada permite borrar la fila.
Los errores de red, 429, 5xx o de sesión conservan el reporte. Los rechazos definitivos conservan
la fila con su motivo (`PendingReport.rejectedReason`), muestran un aviso en Perfil y esperan un
reintento explícito. Un reporte que ya está en camino no se vuelve a enviar desde otro flujo.

Cerrar sesión desde Perfil intenta enviar los reportes pendientes y luego borra lo que la cuenta dejó
en el teléfono: reportes, copias del feed y catálogo en SwiftData (`FeedCacheRecord`), copias de detalle,
borrador y eventos sin enviar. Si quedan
reportes sin enviar, Perfil lo avisa antes. Los menús guardados se conservan. Si la sesión vence sola,
no se borra nada, para que su dueño retome los pendientes al volver a entrar.

El cierre captura usuario/generación antes de esperar el envío y vuelve a comprobarlos después.
La sesión se invalida antes de limpiar y el siguiente login espera a que termine esa limpieza.
`LocalContentStore` ordena en una transacción la purga de reportes/copias; un permiso revocado impide
que una escritura antigua vuelva a crear el feed. `FileStore` es un actor de I/O con invalidación de
sesiones y orden de revisiones de borradores. Los fallos de limpieza se informan; no se borra la base
completa ni se eliminan los guardados para ocultar un error.

El borrador nuevo se autoguarda con debounce de 400 ms y al salir/pasar a segundo plano. Los cambios
del formulario permanecen en memoria ante un fallo de disco y la UI permite reintentar. Una lectura
tardía no reemplaza un formulario ya editado. Publicar/editar/cerrar conservan los permisos y
`expectedVersion` del servidor; se comprueba la sesión antes de borrar borradores o refrescar pantallas.

La cola de analítica interpreta aceptados, duplicados y rechazos individuales. Conserva fallos
temporales y registra hasta 100 rechazos permanentes por cuenta para diagnosticar la calidad de datos;
no reintenta infinitamente un evento inválido ni muestra detalles técnicos al estudiante.

Una base que no abre se conserva: no se elimina el archivo ni se informa falsamente que un reporte
quedó guardado. Este caso se muestra en Perfil y el formulario informa el fallo de persistencia.
