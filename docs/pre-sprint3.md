# Preparación antes de Sprint 3

Base integrada: PR #40 (almacenamiento) y #41 (concurrencia) de Juan Esteban.
Los cambios se revisan en dos PR: [backend #13](https://github.com/EstebanRojas01/UniEat---iOS-Back/pull/13)
y [iOS #42](https://github.com/k-alvarezr/UniEat---iOS/pull/42). Se recomienda aceptar y desplegar
la migración y API del backend antes de distribuir el cliente actualizado. Los PR no despliegan producción.

## Correcciones incluidas

1. ViewModels por funcionalidad y una fachada limitada al envío/sincronización de reportes.
2. Modelos de dominio en archivos por entidad, manteniendo nombres y serialización existentes.
3. Pendientes durables: reintentos conservan UUID y hora observada; los errores temporales y rechazos
   no eliminan trabajo. El servidor deduplica por autor y excluye filas antiguas de la estimación vigente.
4. Aislamiento de respuestas, caché y colas por cuenta; invalidación por generación y orden de solicitud.
5. Renovación de tokens cancelada al cerrar sesión y errores de sesión separados de desconexión.
6. Reloj basado en servidor y tiempo transcurrido para vigencia/fila durante el proceso.
7. Estados distinguibles de carga, vacío real, fallo y copia guardada con fecha y reintento.
8. Conservación de los flujos de publicación, permisos y estrategias concurrentes de Juan.
9. Documentación vigente en `architecture.md` y este archivo; se retira la guía desactualizada de Sprint 2.

## Relación con las issues

Estos cambios preparan puntos de extensión; las issues siguen abiertas y conservan su responsable.

| Issue | Responsable | Punto de extensión preparado | Trabajo propio de Sprint 3 pendiente |
|---|---|---|---|
| #30, BQ nueva | Kevin | `EventService`, sesión y `PerformanceViewModel` | Elegir/implementar BQ-08 o BQ-12 con pipeline y tablero; no se atribuye aquí como terminada |
| #32, multihilo | Kevin | `FeedViewModel`, `SavedMenusViewModel`, servicios inyectables | Grupo de miniaturas y `@ModelActor` de guardados |
| #34, almacenamiento | Kevin | Un solo `LocalDatabase.container`; formato de guardados intacto | SavedMenu/SavedDish, migración desde UserDefaults, snapshots de feed y archivos de fotos |
| #36, conectividad | Kevin | Fuente única de feed/filtros, fecha de caché, ViewModels de filtros y recomendación | Navegación offline completa en esas cuatro vistas y capturas |
| #38, caché | Kevin | Feed/imagen separados de las vistas | Kingfisher, NSCache por usuario/filtros y TTL/costos |
| #39, wiki y sustentación | Ambos | Arquitectura y escenarios verificables descritos | Evidencia visual, prueba en iPhone y coordinación por Teams a cargo del equipo |
| #29, claridad BQ-04 | Juan | `PerformanceViewModel` y sección visual existente | Rediseño coordinado del tablero iOS/HTML |
| #31, multihilo | Juan | Se mantienen async let, lecturas utility y TaskGroup del PR #41 | Dedupl./cancelación de tareas por menú y cualquier mejora restante de su issue |
| #35, conectividad | Juan | Servicios de detalle/publicación/reportes y reintento al reconectar | Terminar y documentar estados offline específicos de sus pantallas |
| #37, caché | Juan | `MenuDetailService` y `PerformanceViewModel` | NSCache de detalles y LRU del panel con parámetros de su issue |

No se cambian automáticamente los responsables, el alcance o el estado de las issues.

## Escenarios de revisión

| Escenario | Comportamiento que debe comprobarse |
|---|---|
| Se pierde la respuesta tras guardar un reporte | El mismo UUID se reintenta y el backend conserva un único reporte |
| Red caída / 429 / error 500 | La fila permanece pendiente; vuelve a intentarse al recuperar servicio |
| Reporte rechazado definitivamente | Permanece guardado; Perfil muestra el motivo y permite reintentar |
| Observación de fila enviada horas después | Se conserva como reporte, pero no cuenta entre las muestras de los últimos 30 minutos |
| Cierre de sesión con una carga en curso | La respuesta anterior no restaura datos ni credenciales |
| Dos cargas con filtros idénticos | Se aplica únicamente el resultado de la solicitud más reciente |
| Reloj del teléfono incorrecto | Con una referencia recibida en el proceso, la vigencia avanza usando uptime |
| Publicar con otra sesión / versión | Los permisos y `expectedVersion` continúan validándose en backend |
| Recuperar borrador mientras se escribe | La lectura tardía no sobrescribe un formulario que ya cambió |
| SwiftData no puede abrir/guardar | Se conserva el archivo existente y se informa que el nuevo reporte no está guardado |

Las pruebas automáticas cubren las fronteras de sesión, orden de respuesta, reloj, SwiftData e identidad
de reintentos. CI también ejecuta las pruebas preexistentes del dominio y construye el cliente.
Las capturas, pruebas de experiencia completa y validación en iPhone real deben registrarse con evidencia
del equipo; este documento no las da por realizadas.
