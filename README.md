# NVMeForge

Copia el Windows de tu equipo a un disco NVMe nuevo (en un adaptador USB o en una ranura interna) y **relee el 100 % de lo que escribió** para comprobar que la copia es idéntica. Pensado para cambiar el disco de una laptop por uno más grande: 512 GB → 2 TB hoy, 2 TB → 4 u 8 TB mañana.

- Un solo `.exe` portable para Windows 10/11 de 64 bits. No se instala y no necesita runtimes.
- Funciona con el disco destino en un adaptador USB, de cualquier marca de disco. Probado con un adaptador UGREEN (chip RTL9210).
- Código abierto bajo [GPL-3.0](LICENSE).

> ⚠️ **Clonar borra por completo el disco destino.** NVMeForge pide que confirmes el modelo y el tamaño exactos del disco que se va a borrar y se detiene si el disco conectado cambió.

## Cómo funciona

1. **Instantánea de C:** con Volume Shadow Copy. Puedes seguir usando el equipo; se copia el estado congelado de ese momento.
2. **Copia en bruto de lo usado:** solo los clústeres ocupados de C:, en bloques de 8 MiB, sin caché de Windows. Las demás particiones del disco (por ejemplo las del fabricante) se copian completas, sector por sector.
3. **Verificación completa:** cada bloque escrito se vuelve a leer del destino y se compara con la huella XxHash64 de lo que se envió. Una sola diferencia = error y el disco no se da por bueno.
4. **Arranque y recuperación:** amplía Windows a todo el disco nuevo, crea la partición de recuperación (WinRE), instala el arranque UEFI con `bcdboot`, conserva las carpetas del fabricante de la partición EFI (HP, Dell, Lenovo…) y desactiva el inicio rápido en el clon para que su primer arranque sea limpio.
5. **Protección del resultado:** deja una marca en el disco terminado para no borrarlo por accidente si vuelves a darle a Clonar.

## Salud y rendimiento

- **Discos:** salud NVMe completa (vida, errores, temperatura, minutos calientes y frenadas por calor registradas), conexión PCIe real (por ejemplo PCIe 4.0 x4) contra su máximo, TRIM y caché de escritura, con un diagnóstico que dice qué hacer.
- **Rendimiento:** las 4 pruebas de CrystalDiskMark (SEQ1M Q8T1, SEQ1M Q1T1, RND4K Q32T1, RND4K Q1T1), lectura y escritura, sobre un archivo temporal oculto de 1 GiB que Windows borra al terminar. Vigila la temperatura mientras mide, compara contra el límite de la conexión y muestra los ajustes de Windows que cambian la medición. Nunca escribe en el disco en bruto.

Cada error tiene un código `NVF-Exxx` con su causa y solución en [ERROR_CATALOG.md](ERROR_CATALOG.md), y cada corrida deja su registro en `%TEMP%\NVMeForge\logs`.

## Requisitos

- Windows 10 u 11 de 64 bits y permisos de administrador.
- Equipo con arranque UEFI. El clon se crea con tabla GPT y arranque UEFI.
- C: en NTFS con clústeres de 4 KiB (lo normal).
- Disco destino distinto del de Windows, con espacio para C: completo más el arranque y la recuperación (normalmente C: + 1.4 GB). NVMeForge calcula y muestra el mínimo exacto.
- Al menos 10 GB libres en C: para la instantánea y, en laptop, el cargador conectado o batería por encima del 60 %.

## Uso

1. Conecta el NVMe destino al adaptador USB (o a la ranura interna).
2. Abre `NVMeForge.exe` y pulsa **Pedir** para dar permisos de administrador.
3. Si hay varios discos conectados, elige en cuál clonar. NVMeForge no adivina: con un solo disco además del de Windows lo preselecciona; con varios, tú eliges.
4. Revisa **Antes de clonar**, confirma y espera. La pantalla muestra un tiempo estimado según la velocidad que midió en tu disco.
5. Cuando diga **Clon terminado y verificado**, apaga el equipo y pon el disco nuevo en lugar del anterior.

Línea de comandos:

```text
NVMeForge.exe --preflight [--target=N]   Diagnóstico sin escribir nada -> %TEMP%\NVMeForge\logs\preflight.log
NVMeForge.exe --clone --target=N [--slow-ok]  Clona en el disco N (lo BORRA). --target es obligatorio; --slow-ok confirma un enlace lento (<60 MB/s) tras ver su tiempo estimado
NVMeForge.exe --version
```

## Lo que todavía no hace

- Copia todas las particiones del disco de origen **excepto las que tienen letra y están en uso** (por ejemplo una D: de datos): esas todavía no, y lo avisa antes de clonar.
- No clona a un disco **más chico** que la partición C: completa, aunque lo usado quepa.
- **El clon queda sin BitLocker:** se copia el contenido descifrado de C:. Si usabas BitLocker, vuelve a activarlo en el disco nuevo.
- No clona a varios discos a la vez ni hace clones programados.
- Equipos con arranque BIOS/MBR: el disco nuevo se prepara para UEFI; el equipo debe poder arrancar en modo UEFI.

## Compilar

Con [Zig 0.15.2](https://ziglang.org/download/):

```text
zig build                 # iterar en Debug: compila mucho más rápido que --release=fast
zig build --release=fast  # solo al final -> zig-out\bin\NVMeForge.exe
zig build test            # pruebas unitarias del motor (en Windows)
```

La caché `.zig-cache` acelera las recompilaciones: no la borres entre iteraciones.

El ejecutable apunta a x86-64-v2 (lo mismo que exige Windows 11 24H2), así que corre en cualquier PC con Windows 11, sea Intel o AMD. La compilación oficial la hace GitHub Actions ([.github/workflows/build.yml](.github/workflows/build.yml)) a partir de este código.

## Privacidad y seguridad

- **NVMeForge no se conecta a internet ni envía datos a ningún lado.** This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.
- La interfaz es una página local servida solo en `127.0.0.1:8999` y abierta en una ventana de Edge (o de Chrome si no hay Edge). Toda acción exige una cabecera propia y el origen local, así que ninguna página web puede ordenar una clonación (NVF-E032).
- El disco de origen solo se lee. Lo que cambia en tu sistema: crea y borra una instantánea VSS de C:, usa temporalmente las letras S:, W:, R:, Z: e Y:, desactiva la suspensión selectiva de USB (con cargador) del plan de energía actual para que el adaptador no se duerma a mitad de la copia, y guarda sus registros en `%TEMP%\NVMeForge`. Puedes volver a activar la suspensión selectiva en Opciones de energía. Para desinstalar, borra el `.exe` y esa carpeta.
- Para reportar una vulnerabilidad, ver [SECURITY.md](SECURITY.md).

## Política de firma de código

Ver [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md).

## Licencia

Copyright (C) 2026 Carlos Javier y los autores de NVMeForge.

Este programa es software libre: puedes redistribuirlo y/o modificarlo bajo los términos de la Licencia Pública General GNU, versión 3 o (a tu elección) cualquier versión posterior. Se distribuye con la esperanza de que sea útil, pero **sin ninguna garantía**. Ver [LICENSE](LICENSE).

Samsung, SK hynix, HP, UGREEN y otras marcas citadas en la documentación pertenecen a sus dueños. NVMeForge no está afiliado a ninguna de ellas.

---

## English summary

NVMeForge clones the running Windows (C:) to a new NVMe drive, including drives in USB enclosures of any brand, from a live VSS snapshot. It copies only allocated clusters, **re-reads 100 % of what it wrote** and compares it against XxHash64 digests of what was sent, then extends Windows to the whole new drive, recreates WinRE and installs UEFI boot. It is a single portable `.exe` for Windows 10/11 x64, licensed under GPL-3.0-or-later. It never connects to the internet. Build with Zig 0.15.2: `zig build --release=fast`.
