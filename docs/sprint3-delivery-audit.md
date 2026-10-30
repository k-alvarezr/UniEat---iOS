# Sprint 3: auditoría de implementación y entrega

Referencias revisadas: descripción de la actividad (seis páginas) y rúbrica `VivaVoce3` (una página),
entregadas por el equipo. Fecha de entrega indicada: **31 de octubre de 2026, 05:00 America/Bogota**.
El uso de IA sigue la autorización actual comunicada por Kevin; no se reproduce la advertencia anterior.

Esta matriz distingue código, integración, pruebas automatizadas, evidencia real y evaluación oral.
Cumplir un mínimo técnico no equivale a prometer una nota ni a certificar una explicación individual.

## Implementación individual de Kevin

| Criterio | Implementación y justificación | Validación / estado |
|---|---|---|
| BQ nueva, diferente de Sprint 2 | BQ-08, Type 3, definida por Kevin en Sprint 1: intervención sobre el indicador de fila; BQ-03 continúa como funcionalidad anterior | Asignación por usuario/sesión, exposición elegible y seguimiento de diez minutos; pruebas de API/SQL en backend |
| Pipeline conectado a una BD y al mismo tablero | `WaitIndicatorPilot` → eventos/reportes → Supabase → `bq08_snapshot` → panel iOS/HTML existente | Backend desplegado en `api-v1` v12; datos vacíos/insuficientes se presentan con honestidad; faltan participantes reales |
| Concurrencia propia | `LocalContentStore` usa `@ModelActor` para el I/O relacional; `FeedImageStore` usa actor, trabajo estructurado y TaskGroup con máximo cuatro descargas compartidas | Separación de MainActor/UI y ejecutores de I/O, resultados Sendable, cancelación y límites de sesión; XCTest |
| Almacenamiento relacional propio | `SavedMenu`/`SavedDish` y snapshots/catálogo en SwiftData, por usuario y versión | Migración sin borrar reportes de Juan, relaciones/cascadas, actualización y recuperación tras relanzar |
| Archivos y preferencias propios | Imágenes procesadas en el disco de Kingfisher y migración de archivos anteriores; UserDefaults para filtros, cola de eventos y metadatos de cuenta | Caché limitada, sin otra copia del original; no se almacenan tokens en preferencias; los eventos no se borran sin confirmación coherente |
| Caché NSCache | `FeedMemoryCache`: usuario+filtros, TTL 30 s, 12 entradas y objetivo de coste de JSON 4 MiB | Volver a un contexto reciente evita red; recarga forzada y cambio de cuenta invalidan; expulsión de NSCache puede ocurrir antes |
| Caché LRU propia | `OfflineFilterCache`: diccionario + lista doble, cuatro resultados locales, TTL 30 s, máximo 1 MiB de JSON por entrada | Lookup/promoción/retirada O(1); filtrado y codificación siguen siendo O(n). Caduca antes de cambios de vigencia/fila; limpia al cambiar catálogo/cuenta/publicación |
| Biblioteca de imágenes | Kingfisher 8.14.0: un almacén activo, 50 MiB/100 imágenes de memoria, 50 MiB/siete días en disco, procesador 720×480 | Request broker común, máximo cuatro solicitudes, cancelación por consumidor; pruebas de caché/migración, medición física pendiente |
| Conectividad en cuatro vistas propias | Hoy, Filtros, Guardados y Elige por mí conservan navegación y acciones locales; fecha, vencimiento y ausencia de copia visibles | `docs/offline-screens.md`, pruebas de filtrado, almacenamiento, reloj y reconexión; capturas físicas pendientes en #36/#44 |
| Corrección transversal adicional | Avisos por vista, hoja de reportes, detalle local, permisos en copia de cuenta y métricas sin spinner infinito | PR #61 sobre #52/#53; no cambia ranking, fila ni contrato del servidor |

La LRU local complementa NSCache y Kingfisher con un propósito distinto: alternar combinaciones de
filtros sin red. No duplica el almacenamiento de imágenes ni sustituye la LRU del panel que Juan tiene
planificada en #37. Los máximos de memoria descritos son políticas de coste/cantidad, no medidas de RAM
real ni garantías de que el sistema retenga una entrada. Las estructuras se justifican por su uso real;
la asignación de puntos corresponde al docente tras la demostración y explicación.

## Trabajo de Juan y límites de autoría

Se preservan sus cambios de almacenamiento, concurrencia, fachadas, comentarios y aviso de carga.
Su detalle usa archivo y `async let`; su cuenta carga datos independientes concurrentemente; la cola
de reportes conserva SwiftData y reintentos. Las correcciones conjuntas de sesión/archivos se identifican
como tales y no convierten esas estrategias originales en trabajo exclusivamente de Kevin.

Permanecen a cargo de Juan los issues #29 (claridad BQ-04), #37 (NSCache de detalle y LRU del panel),
#43 y backend #15 (BQ-07 nueva), #59 (revisión/regresiones) y #60 (Instruments). La BQ-04 de Sprint 2
no reemplaza su BQ nueva. La infraestructura de BQ-08 permite compartir asignaciones y BD, pero no
implementa por sí sola su evaluación común de BQ-07. El trabajo de iOS no acredita el del equipo Android.

## Inventario y conectividad de toda la app

El inventario de Sprint 2 y Sprint 3 está en la wiki y `docs/sprint3.md`. La matriz de
[navegación por vista](offline-screens.md) incluye autenticación, feed, copia, filtros, recomendación,
guardados, detalle, reportes, fila, publicación, perfil, solicitudes, roles, aprobaciones, paneles y galería.
La rúbrica dice que un mensaje genérico no basta: se conserva funcionalidad local y se explican límites.

Publicación y permisos siguen requiriendo confirmación del servidor. La copia de cuenta mantiene la
navegación después de relanzar sin red, pero no habilita escrituras privilegiadas. Las listas administrativas
y los paneles disponibles se conservan en memoria; si se reinicia sin copia no se inventa una lista vacía
ni métricas en cero. Crear una cuenta nueva requiere conexión. Maps/geocodificación tienen sus límites
propios; GPS y coordenadas ya descargadas pueden funcionar sin internet.

## Colaboración y Kanban

Se reutiliza [el proyecto compartido](https://github.com/users/k-alvarezr/projects/2), conservando Sprint 2,
con una [vista Kanban de Sprint 3](https://github.com/users/k-alvarezr/projects/2/views/6) por milestone.
Kevin administra el proyecto y Juan tiene permiso Write. Flujo: Backlog → Ready → In progress →
In review → Done. Los issues de implementación con PR abierto quedan en revisión; pruebas físicas,
mediciones y entrega conservan sus estados pendientes. No se cierra un issue solo para igualar cantidades.

La integración del front requiere revisión de Juan: #52 → #53 → #61, actualizando bases tras cada merge.
No se afirma una aprobación ni un merge antes de que ocurran. Backend usa commits y push a `main`
por acuerdo explícito del equipo, con CI; no se crean PR de backend. Conservar commits, milestones,
issues y revisión del front como evidencia real del proceso.

## Comprobación individual antes del viva voce

Kevin debe poder mostrar y explicar su código y el de Juan, usando ejemplos concretos:

1. Concurrencia: alcance de MainActor, aislamiento del actor de datos, TaskGroup, límite de descargas,
   resultados, cancelación y por qué `async let` de cuenta/detalle de Juan ejecuta trabajo independiente.
2. Almacenamiento: relaciones/cascadas por usuario, actualización/migración y cola de reportes; archivos
   atómicos de detalle/borrador de Juan y diferencia entre preferencias, caché y datos pendientes.
3. Conectividad: navegar, guardar y filtrar sin red; pérdida de red a mitad de petición, retorno a red,
   cuenta distinta y reloj; explicar por qué permisos/publicación no se confirman offline.
4. Caché: clave, TTL, límites y expulsión de NSCache, LRU y Kingfisher; invalidación temporal, por usuario
   y catálogo; estructuras de Juan cuando estén implementadas. No atribuir una estrategia solo planeada.

La rúbrica pide una justificación inicial de los cuatro grupos, aproximadamente un minuto por grupo,
y poder explicar las decisiones del compañero de la misma plataforma. El documento apoya el ensayo;
la comprensión y la presentación son trabajo individual y no se marcan como realizadas automáticamente.

## Pendientes que impiden declarar terminada la entrega

- Integrar los PR de iOS tras revisión y pasar sus checks.
- Ejecutar en iPhone real la matriz por rol/vista, relanzamiento offline, actualización con datos anteriores,
  cambio de cuenta, GPS, publicación/edición/cierre y recuperación de pendientes; identificar dispositivo/iOS/commit.
- Subir capturas auténticas legibles por estrategia y vista; medir con Instruments en #60.
- Completar las implementaciones individuales pendientes de Juan y del subgrupo Android.
- Reunir participantes voluntarios y resultados reales si se pretende mostrar resultados del piloto;
  sin ellos, mostrar explícitamente muestra insuficiente, sin atribuir eficacia a datos de prueba.
- Ensayar la explicación cruzada; grabar y enlazar el video ético de seis minutos y verificar acceso.
- Entregar el enlace del repositorio en Bloque Neón antes del plazo y coordinar con el monitor la prueba
  iOS real por Teams. Esos mensajes y la entrega los realiza el equipo; no se enviaron durante esta implementación.

La actividad vincula elegibilidad del viva voce con los componentes obligatorios, prácticas del repositorio
y demostración en dispositivo. El estado del código por sí solo no certifica esos requisitos humanos.
