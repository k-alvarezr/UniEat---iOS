# UniEat iOS

Aplicación iOS de UniEat. Este repositorio contiene la app, el backend y la documentación del Sprint 2. La especificación de producto está en la [wiki del proyecto](https://github.com/EstebanRojas01/Moviles/wiki).

## Preparación en Windows

- Git, Node.js, VS Code y la extensión oficial de Swift.
- Swift para Windows permite compilar y probar paquetes Swift independientes de iOS.
- Desde PowerShell, `./scripts/swift-core-windows.ps1 build` compila `UniEatCore`. El script carga las herramientas C++ de Visual Studio y configura las rutas locales del SDK automáticamente.
- `npm ci` instala la versión fijada de Supabase CLI. `npx supabase --version` comprueba la instalación.
- `npx supabase start` requiere Docker Desktop en ejecución. La configuración local está en `supabase/config.toml`.

Windows no incluye Xcode ni los SDK de iOS: la app SwiftUI se compila y ejecuta en un Mac. El código de dominio que no importe SwiftUI, MapKit u otros frameworks de Apple puede mantenerse en un paquete Swift para probarlo también en Windows.

## Preparación en Mac

1. Instalar Xcode y sus componentes de iOS.
2. Clonar este repositorio.
3. Ejecutar `npm ci` para usar la misma versión de Supabase CLI.
4. Abrir el proyecto Xcode de la app cuando se añada al repositorio.
5. Ejecutar primero en el simulador y validar las funciones de dispositivo en un iPhone.

## Backend local

```powershell
npm ci
npm run backend:start
npm run backend:status
```

No añadir claves privadas ni archivos `.env` al repositorio. La configuración pública de Supabase y las variables necesarias para la app se documentarán cuando se cree el proyecto.
