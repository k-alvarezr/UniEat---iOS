# Sprint 3 · implementación iOS

Seguimiento: [milestone iOS](https://github.com/k-alvarezr/UniEat---iOS/milestone/4),
[wiki del sprint](https://github.com/EstebanRojas01/Moviles/wiki/Sprint-3).
La base es `main` con los PR #40 y #41 de Juan y la preparación #42 integrados.
Se conservan sus modelos de reportes, archivos de detalle/borrador y estrategias concurrentes.

## Responsabilidad y alcance

| Integrante | Issues | Entrega |
|---|---|---|
| Kevin | #30, #32, #34, #36, #38 | BQ-08; miniaturas concurrentes; guardados y feed en SwiftData; Hoy/Filtros/Guardados/Elige por mí offline; Kingfisher y NSCache |
| Juan | #29, #31, #35, #37, #43 | Claridad BQ-04; concurrencia propia; detalle/reportar/publicar offline; caché de detalle/panel; nueva BQ-07 |
| Ambos | #39, #44 | Wiki, evidencias reales, prueba en iPhone, video ético y entrega |

Los cambios de Kevin se revisan en [iOS #45](https://github.com/k-alvarezr/UniEat---iOS/pull/45)
y [backend #16](https://github.com/EstebanRojas01/UniEat---iOS-Back/pull/16).
El backend #16 depende de [preparación #13](https://github.com/EstebanRojas01/UniEat---iOS-Back/pull/13).
Aplicar migraciones en orden, desplegar `api-v1` y luego distribuir el cliente. Abrir un PR no despliega producción.

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

La infraestructura reserva una clave independiente para BQ-07. Juan debe implementar su intervención y una
evaluación posterior común a ambos grupos: comparar solo confirmaciones sería favorecer el grupo que puede
confirmar. Sus métricas y su endpoint siguen pendientes en las issues iOS #43 y backend #15.

## Concurrencia y persistencia de Kevin

- `FeedImageStore.prefetch`: `withTaskGroup`, hasta cuatro descargas hijas simultáneas; cancelación al cambiar
  cuenta o resultado. ImageIO reduce a un máximo de 720 px fuera de MainActor antes de guardar JPEG.
- `LocalContentStore`: `@ModelActor` construido en tarea utility mediante `LocalContentService`, con contexto
  propio sobre el **mismo ModelContainer** de reportes. Solo salen valores `Sendable`; UI en MainActor.
- `SavedMenu` → `SavedDish` usa relación inversa y borrado en cascada. Metadatos del menú y platos relacionados
  se reconstruyen sin duplicar los platos en el JSON. Usuario y publicación identifican el guardado.
- Migración desde `unieat.saved-menus.<usuario>`: deduplica, conserva filas existentes y confirma la transacción
  antes de eliminar la clave anterior. Un fallo conserva el origen e informa el error.
- `FeedCacheRecord`: snapshots por usuario/filtros y catálogo sin filtros; hasta 24 combinaciones por cuenta
  más un catálogo. El calentamiento automático no cuenta como búsqueda BQ-03.
- Miniaturas públicas en `Caches/unieat-feed-images/<SHA256(URL)>.jpg`: escritura atómica, siete días,
  limpieza de archivos más antiguos por encima de 50 MiB. Es caché recuperable, no persistencia garantizada.

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
| Kingfisher 8.14.0 | Memoria 50 MiB / 100 imágenes; disco 100 MiB / 7 días; downsampling y cancelación al desaparecer | Reduce red/decodificación y permite reutilizar imágenes ya vistas; offline consulta caché/miniatura local |
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

| Evidencia real a adjuntar en #44 / wiki | Responsable | Estado |
|---|---|---|
| iPhone: abrir online, guardar, activar modo avión, cerrar/abrir app, recorrer cuatro vistas y recuperar red | Kevin | Pendiente de dispositivo |
| iPhone: detalle/reportar/publicar sin conexión, concurrencia y cachés propias | Juan | Pendiente de su implementación y dispositivo |
| Control/tratamiento con datos reales y tabla del mismo período en iOS/HTML | Ambos | Pendiente de despliegue y participantes |
| Capturas identificadas por vista/estrategia, dispositivo, versión y commit | Cada autor | Pendiente |
| Video ético de seis minutos, acceso a enlaces y coordinación de entrega en Teams | Ambos | Pendiente de grabación/entrega humana |

No se han medido participantes ni rendimiento físico. Cada integrante debe poder explicar las decisiones
y el código del compañero; los comentarios y enlaces de arquitectura forman parte de la documentación viva.
