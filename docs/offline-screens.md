# Conectividad y navegación por vista

La protección combina avisos específicos con funciones locales. El aviso compartido no reemplaza las
estrategias de cada vista: la rúbrica del viva voce exige navegación y funcionalidades offline.

`ConnectivityService` diferencia una ruta de red ausente de un servicio UniEat que no responde.
Todas las peticiones de `APIClient` actualizan la disponibilidad; una cancelación o respuesta de otra
sesión no cambia ese estado. Reintentar comprueba `/health` sin token de usuario y comparte una sola
comprobación entre pantallas. No se presenta un error 500 como una búsqueda vacía.

## Matriz de funcionamiento

| Vista | Navegación y función sin red | Recuperación / límite |
|---|---|---|
| Login y registro | Conserva el formulario abierto y explica por qué no puede enviarse | Reintentar el servicio y luego entrar; no existe autenticación offline de cuentas nuevas |
| Hoy | Lee copia por usuario/filtros o catálogo local; abre filtros, detalle y guardados; descarta vencidos | Fecha de copia, estado sin copia y actualización explícita al recuperar red |
| Copia de menús | Sigue navegable desde Hoy o la galería, distingue copia ausente de copia sin coincidencias | Reintento forzado; no afirma estar sin internet si la red ya volvió |
| Filtros | Edita/restablece filtros y aplica reglas al catálogo descargado; GPS con coordenadas disponibles | LRU de resultados locales recientes; invalida en cambios temporales, catálogo/cuenta/publicación; mismas reglas por plato |
| Elige por mí | Recorre las opciones locales compatibles y abre el detalle | Señala antigüedad; no crea alternativas si falta copia compatible |
| Guardados | Lee relaciones SwiftData por cuenta; abre el menú guardado y permite quitarlo localmente | Conserva fecha y señala vencidos; cambios remotos se verifican en detalle |
| Detalle | Lee archivo o snapshot inicial; permite guardar, elegir, registrar llegada y preparar reporte | Sin ruta no intenta HTTP; pull-to-refresh y reconexión recargan sin inflar BQ-04 |
| Reportar y tiempo de fila | Mantiene formulario; el envío guarda en la cola SwiftData antes de confirmar que está pendiente | Reintentos idempotentes por cuenta y hora observada; error visible si el almacenamiento falla |
| Publicar / editar / cerrar | Formulario y borrador de publicación local; mantiene datos ya cargados y distingue lista ausente de lista vacía | Publicar/cerrar requieren conexión y cuenta verificada; revalida cuenta y lista al reconectar; el servidor controla `expectedVersion` |
| Perfil | Datos de cuenta y reportes locales; acceso a guardados y cierre de sesión | Cuenta guardada identificada por fecha; actualización verifica rol/membresías con el servidor |
| Solicitar establecimiento | Mantiene el formulario y pin seleccionado; GPS puede operar sin internet | Geocodificar y enviar requieren red; conserva campos ante fallo; no concede permisos locales |
| Roles / aprobaciones | Listas ya recibidas permanecen consultables dentro de Perfil | Acciones bloqueadas sin red/cuenta verificada; una lista no descargada no significa cero solicitudes |
| Panel admin / mis métricas | Conserva el último panel en memoria para el período exacto y deja cambiar de período/navegar | Sin copia muestra estado explícito; pausa polling sin red, retoma al reconectar; no hay copia entre procesos |
| Galería de pantallas | Enlaces siguen utilizables con los menús locales disponibles | Cada destino conserva su propia protección y límites de rol |

El panel por períodos sigue usando el almacenamiento en memoria existente. NSCache de detalles y LRU del
panel son tareas de Juan en #37; esta corrección no las presenta como ya implementadas. Los formularios
de cuenta se conservan durante su vista/sesión; no se afirma persistencia tras cerrar la app. El archivo de
borrador existente corresponde a nuevas publicaciones, no a una cola automática de ediciones del servidor.

## Cuenta guardada y permisos

Supabase Auth entrega inicialmente un perfil estudiante; `/me` es la autoridad del rol. Se conserva la
última respuesta de cuenta por UUID para mantener pestañas, locales y navegación en un relanzamiento
sin red. Esa copia se etiqueta y `isAccountVerified` empieza en `false`: no autoriza administración ni
publicación. La verificación remota reemplaza la copia incluso si revoca el rol. Otro UUID no puede
recuperarla; el cierre manual la elimina y el vencimiento automático conserva los datos para su dueño.
Los tokens continúan exclusivamente en Keychain. El backend mantiene sus verificaciones en cada ruta.

## Validación automatizada

`OfflineScreenTests` cubre ruta ausente frente a servicio inaccesible, comprobación pública sin token,
recuperación compartida, cancelación, expiración de un token viejo, formulario de acceso, cuenta guardada
sin autorización, separación/borrado por usuario, métricas sin copia, pérdida de red durante una respuesta,
recuperación, bloqueos administrativos, lista aún no descargada, respuesta de otra sesión y detalle local.
Continúan las pruebas anteriores de filtrado, vencimiento, persistencia, borradores, imágenes y reportes.

`OfflineFilterCacheTests` verifica promoción/expulsión LRU, aislamiento, borrado, retroceso de reloj y
caducidad en vencimiento, inicio de una publicación y fin de la ventana de evidencia de fila.

La compilación iOS y XCTest se ejecutan en CI macOS. No se atribuye a CI una prueba en iPhone físico.
Registrar los escenarios reales, dispositivo, iOS, commit y capturas en #44/#59 y la wiki antes de entrega.
