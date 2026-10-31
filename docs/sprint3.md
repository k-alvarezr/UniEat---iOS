# Sprint 3 · implementación iOS

Seguimiento: [milestone iOS](https://github.com/k-alvarezr/UniEat---iOS/milestone/4),
[wiki del sprint](https://github.com/EstebanRojas01/Moviles/wiki/Sprint-3).
La base es `main` con los PR #40 y #41 de Juan y la preparación #42 integrados.
Se conservan sus modelos de reportes, archivos de detalle/borrador y estrategias concurrentes.

## Responsabilidad y alcance

| Integrante | Issues | Entrega |
|---|---|---|
| Kevin | #30, #32, #34, #36, #38 | BQ-08; miniaturas concurrentes; guardados y feed en SwiftData; Hoy/Filtros/Guardados/Elige por mí offline; Kingfisher y NSCache |
| Juan | #29, #31, #35, #37, #43 | Claridad BQ-04; concurrencia propia; detalle/reportar/publicar offline; caché de detalle/panel; BQ-07 (fila habitual por local) |
| Ambos | #39, #44 | Wiki, evidencias reales, prueba en iPhone, video ético y entrega |

La implementación de Kevin [iOS #45](https://github.com/k-alvarezr/UniEat---iOS/pull/45) está integrada,
junto con los comentarios y ajustes de Juan #49/#51. El backend integra reportes y BQ-08 mediante
commits y push directos a `main`; sus PR históricos #13/#16 están cerrados. Ese es el flujo vigente del
backend, con CI en cada push. Aplicar migraciones en orden, desplegar `api-v1` y luego distribuir el cliente:
un push al repositorio no despliega Supabase.

## BQ-08 · indicador de fila y cambio de decisión

Pregunta original de Kevin, tipo 3: ¿mostrar el indicador reduce selecciones iniciales seguidas,
en diez minutos, por una queja explícita de fila demasiado larga o por elegir otro establecimiento?

1. Un estudiante participa voluntariamente desde Perfil. Puede retirarse; la app sigue siendo utilizable.
2. Antes del feed en línea, el servidor asigna aleatoriamente `control` o `treatment` a la sesión.
   Los reintentos recuperan la misma asignación. El cliente no elige variante.
3. Ambos grupos usan el mismo ranking. Control oculta la fila y los fragmentos de explicación sobre fila
   en tarjetas y detalle; tratamiento conserva el indicador. Si falla la asignación se conserva la experiencia
   habitual, sin atribuir esos eventos al experimento.
4. Una impresión visible transporta asignación, sesión, publicación, versión, disponibilidad del indicador,
   si se mostró y fuente `live`. Las copias offline y el feed sin evidencia de fila no forman muestra elegible.
5. Se toma la primera selección elegible por sesión asignada, con impresión previa de esa versión.
   El denominador requiere diez minutos completos de seguimiento. Los casos en curso se muestran aparte.
6. Resultado = queja `long_line` **sin minutos numéricos** o selección de otro establecimiento por el mismo
   usuario en esos diez minutos. Ambos hechos juntos cuentan una sola vez. Un reporte normal de minutos
   no significa queja. Se usa `observedAt`, conservado por la cola offline de Juan y la preparación.
7. PostgreSQL calcula conteos/tasas; `/admin/dashboard` los entrega al mismo panel iOS y HTML.
   Se muestran 7/28 días, tamaños de muestra y diferencia tratamiento − control en puntos porcentuales.
   Cada tasa exige al menos cinco seguimientos completos; la diferencia exige ambos grupos suficientes.

El umbral cinco es una regla de presentación, no una prueba de significancia. Las selecciones no son compras;
las quejas son autorreportadas. Participación voluntaria, repeticiones del mismo estudiante, ausencia de quejas
no observadas y cambio entre variantes en distintas sesiones limitan una conclusión causal. No hay resultados
reales hasta ejecutar el piloto; las fixtures de pruebas no se insertan en producción.

BQ-07 de Juan (tipo 2): ¿qué tiempo de espera puede mostrar UniEat para el local elegido en este momento, con
reportes recientes, reportes históricos comparables, su antigüedad y cantidad? El server usa la mediana de los
últimos 30 min (mínimo 3 estudiantes) o, si no alcanza, lo habitual del mismo local, día y hora en 4 semanas;
el detalle muestra "Normalmente ~X min a esta hora" y el tablero web lista la estimación por local.

## Concurrencia y persistencia de Kevin

- `FeedImageStore.prefetch`: `withTaskGroup`, hasta cuatro hijos de I/O. Precarga y tarjetas pasan por un
  coordinador común de solicitudes por URL y el mismo manager/procesador de Kingfisher. Se conservan
  downsampling (720 × 480), cancelación por consumidor y trabajo de imagen fuera del actor de UI.
- `LocalContentStore`: `@ModelActor` construido en tarea utility mediante `LocalContentService`, con contexto
  propio sobre el **mismo ModelContainer** de reportes. Solo salen valores `Sendable`; UI en MainActor.
- `SavedMenu` → `SavedDish` usa relación inversa y borrado en cascada. Metadatos del menú y platos relacionados
  se reconstruyen sin duplicar los platos en el JSON. Usuario y publicación identifican el guardado.
- Migración desde `unieat.saved-menus.<usuario>`: deduplica, conserva filas existentes y confirma la transacción
  antes de eliminar la clave anterior. Un fallo conserva el origen e informa el error.
- `FeedCacheRecord`: snapshots por usuario/filtros y catálogo sin filtros; hasta 24 combinaciones por cuenta
  más un catálogo. El calentamiento automático (`refresh=auto`) no cuenta como búsqueda BQ-03; el backend
  desplegado lo excluye. Cerrar sesión desde Perfil borra estas
  filas de la cuenta; los `SavedMenu` se conservan. La copia no guarda referencia de hora: `ServerClock`
  usa la diferencia con el servidor de la última respuesta.
- Imágenes públicas: una caché activa de Kingfisher con archivos SHA-256 de URL/procesador, límite de
  disco 50 MiB y vencimiento configurado de siete días. Las versiones anteriores tenían JPEG propios y
  caché Kingfisher por separado: se importan al usarlos, incluso offline, y se retira la copia antigua
  solo después de comprobar la nueva copia en disco. Los archivos antiguos aún no usados pueden
  ocupar espacio temporalmente hasta migrarse o vencer. Es caché recuperable, no persistencia garantizada.

La base no se borra si falla una apertura/migración. Las pruebas incluyen abrir un archivo con el esquema
original de reportes y agregar guardados sin perder esos reportes ni sus relaciones.

## Conectividad y caché por vista

| Vista | Con red | Sin red / servicio no disponible | Recuperación |
|---|---|---|---|
| Hoy | Feed filtrado; copia durable y calentamiento de catálogo | Copia exacta o catálogo filtrado localmente, fecha y aviso; no aparecen menús vencidos/cerrados | Reintentar o pull-to-refresh fuerza red |
| Filtros | API aplica restricciones y ranking | Mismas restricciones sobre catálogo; presupuesto/dieta deben coincidir en un mismo plato; se conserva orden original y se identifica copia | Nuevos filtros solicitan red cuando vuelve |
| Guardados | Actor persiste menú/platos por cuenta | Lista completa conservada entre aperturas; fecha del guardado; detalle abre snapshot y conserva flujos de Juan | Detalle actualiza vigencia/reportes al recuperar servicio |
| Elige por mí | Usa feed y filtros aplicados | Usa el mismo resultado offline, sin inventar fila ni volver a ordenar | Recarga mediante feed compartido |

Sin catálogo o copia compatible se informa que no se pudo actualizar; no se presenta como una búsqueda en
línea sin resultados. GPS puede seguir funcionando sin internet y usa coordenadas ya descargadas; las rutas
de Maps dependen de su propia disponibilidad. Un cierre remoto desconocido no puede verificarse sin red.

| Caché | Política | Motivo |
|---|---|---|
| Feed `NSCache` | Usuario + filtros; TTL 30 s; 12 entradas; costo objetivo 4 MiB del JSON | Evita repetir solicitudes al navegar; refresco explícito ignora la caché; cierre/cambio de cuenta la limpia |
| Kingfisher 8.14.0 | Caché activa única: memoria 50 MiB / 100 imágenes; disco 50 MiB / 7 días; mismo procesador para UI y precarga | Solicitudes compartidas por URL y máximo cuatro trabajos simultáneos; UI lee solo caché; migración offline de ambas cachés anteriores |
| SwiftData | Copia durable sin TTL de eliminación; vigencia comprobada con reloj del servidor | Recuperar datos al relanzar; siempre avisar antigüedad y limitación de actualización |

`NSCache` puede expulsar entradas antes del límite; no garantiza persistencia. Las fotos públicas pueden
compartir caché entre cuentas; el JSON autenticado usa sesión efímera sin URLCache y se separa explícitamente
por usuario en las cachés de aplicación. La medición real de memoria, energía y latencia requiere Instruments
y dispositivo; estos parámetros son límites iniciales, no resultados de un benchmark.

## Verificación y evidencia pendiente

CI ejecuta pruebas de reglas del paquete y XCTest de aplicación sobre simulador iPhone. Las regresiones
cubren migración idempotente y relacional, actualización de esquema con reportes existentes, aislamiento
por usuario, TTL, catálogo offline, diferencia entre queja/observación, control del piloto y cuatro descargas
máximas con downsampling. Se mantienen las pruebas previas de sesión, vigencia, orden de respuestas y reportes.
El backend prueba asignación/autorización/metadata, agregación con ventanas completas e insuficientes y RLS.

Las correcciones posteriores conservan la fachada y comentarios de Juan. Añaden regresiones de reloj
modificado, cierre de una sesión mientras entra otra, limpieza con escrituras pendientes, autoguardado
de borradores y confirmación parcial de eventos. La política y sus límites están en
[Arquitectura · sesión, vigencia y sincronización](architecture.md#sesión-vigencia-y-sincronización).

La optimización del feed conserva identidad por publicación; cambia solo la tarea que registra la exposición
si cambian sesión, versión o elegibilidad del piloto. Un refresco compatible mantiene su resultado en pantalla
y no vuelve a leer/aplicar disco. La respuesta de red se muestra antes de esperar su persistencia. Un resultado
vacío válido también es un snapshot compatible. El catálogo usa su fecha persistida, un feed sin filtros puede
servir de catálogo y el calentamiento no inicia descargas de fotos de toda la base. Publicar/editar/cerrar
invalida memoria y frescura de catálogo antes de forzar red.

| Evidencia real a adjuntar en #44 / wiki | Responsable | Estado |
|---|---|---|
| iPhone: abrir online, guardar, activar modo avión, cerrar/abrir app, recorrer cuatro vistas y recuperar red | Kevin | Pendiente de dispositivo |
| iPhone: detalle/reportar/publicar sin conexión, concurrencia y cachés propias | Juan | Pendiente de su implementación y dispositivo |
| Control/tratamiento con datos reales y tabla del mismo período en iOS/HTML | Ambos | Backend desplegado/verificado en api-v1 v12; participantes y resultados reales pendientes |
| Capturas identificadas por vista/estrategia, dispositivo, versión y commit | Cada autor | Pendiente |
| Video ético de seis minutos, acceso a enlaces y coordinación de entrega en Teams | Ambos | Pendiente de grabación/entrega humana |

No se han medido participantes ni rendimiento físico. Cada integrante debe poder explicar las decisiones
y el código del compañero; los comentarios y enlaces de arquitectura forman parte de la documentación viva.

## Cobertura por vista y revisión individual (#61)

La [matriz de conectividad](offline-screens.md) describe navegación local, recuperación y límites de toda
la app, no solo un aviso compartido. La [auditoría de entrega](sprint3-delivery-audit.md) enlaza criterios,
autoría, código y pendientes humanos del entregable/viva voce. La copia de cuenta mantiene pestañas tras
relanzar offline, pero no autoriza publicaciones ni cambios de roles hasta verificar la cuenta con el servidor.

Kevin incorpora además `OfflineFilterCache`: LRU de cuatro resultados de filtros locales, TTL máximo
30 s, hasta 1 MiB de JSON por entrada, caducidad anterior a cambios de vigencia/fila e invalidación por
cuenta/catálogo/publicación. Complementa NSCache de respuestas online y Kingfisher, sin otro almacén de
imágenes. No sustituye la LRU del panel de Juan (#37) ni representa una medición de rendimiento físico.
