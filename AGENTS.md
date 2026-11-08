# NVMeForge — Memoria de Ingeniería y Reglas del Proyecto (AGENTS.md)

## 1. Propósito y Alcance
**NVMeForge** (`C:\DevWork\Depredador\NVMeForge`) es un clonador de Windows a NVMe de 7 etapas con verificación del 100 % de lo escrito, benchmark de lectura y telemetría real para Windows 10/11 x64, separado de `GACO-Core`. **Código abierto (GPL-3.0-or-later)** desde la v2.7.0: todo lo que no deba publicarse vive en `_privado\` o en archivos `*.bak*` (ambos ignorados por git).

## 2. Regla Estricta: Cero `.ps1` (100% Nativo 64-Bit `build.zig`)
1. **PROHIBIDO usar scripts `.ps1`** para construir, validar iconos o ejecutar lógica del sistema. Todo se construye con `build.zig` (`zig build --release=fast`, pruebas con `zig build test`) y vive dentro de `NVMeForge.exe`. El motor Rust anterior (`Cargo.toml`, `main.rs`) quedó en `_privado\legado-rust` y no se usa.
2. **100% 64-Bit Nativo (`PE32+ x86_64`, `Machine = 0x8664`, CPU base `x86_64_v2`)**: prohibido volver a un modelo de CPU concreto (`znver4` solo corría en AMD Zen 4; NVF-E038).
   - Prohibido generar binarios de 32 bits (`PE32 0x014C`) o instalar en `Program Files (x86)`.
3. **100% Portable en un Solo Ejecutable (`bin\NVMeForge.exe` y `dist\NVMeForge-Portable-x64.exe`)**:
   - Todos los recursos (`ui.html`, `nvmeforge.ico` de 9 resoluciones) se incrustan en el binario con `@embedFile`. Prohibido incrustar o servir logotipos de marcas (Samsung, SK hynix, HP, AMD, Magician): no son nuestros.
   - Subsistema GUI nativo (`--subsystem windows` / `Subsystem = 2`) para evitar cualquier parpadeo de consola.

## 3. Catálogo de Errores Corregidos (Prohibido Repetirlos)
> **Fuente única de verdad:** [`ERROR_CATALOG.md`](ERROR_CATALOG.md) — IDs `NVF-Exxx` en orden cronológico, con cuándo/cómo lo reportó el usuario, etapa del flujo, causa, corrección, evidencia y regla.
> Todo mensaje `❌` de la UI debe llevar su ID `[NVF-Exxx]`. Todo error nuevo se registra en `ERROR_CATALOG.md` antes de corregirlo.
> Logs de rastreo: `%TEMP%\NVMeForge\logs\clone_run.log` (+ `<paso>.log` por comando). Diagnóstico sin riesgo: `NVMeForge.exe --preflight`.

Resumen de reglas (detalle en el catálogo):

0. **NVF-E007 (diskpart)**: `diskpart /s` aborta el script completo en el primer comando fallido sin `noerr`. `select volume X` no admite `noerr` → nunca seleccionar algo que puede no existir (un `select volume` por script). Siempre capturar la salida con `runLoggedCommand`/`runDiskpartScript` (nunca `runHiddenCommandWait` en el flujo de clonación).
0. **NVF-E012 (JSON)**: `updateProgress` escapa todo con `jsonEscapeInto`; escribir los textos normales, sin pre-escapar `\\`.
0. **NVF-E013 (tamaños)**: tamaño de partición = `getVolumePartitionBytes` (`VOLUME_DISK_EXTENTS`), nunca `GEOMETRY_EX` sobre un volumen.
0. **NVF-E014 (proceso)**: borrar archivos puntuales, nunca carpetas completas sin listar su contenido; probar cada comando antes de documentarlo.
0. **NVF-E015 (MSR)**: `convert gpt` ya crea el MSR; no añadir `create partition msr`.
0. **NVF-E016 (comandos colgados)**: todo comando externo recibe stdin = `NUL` (vía `runLoggedCommand`) y banderas no interactivas (`chkdsk /f /x`).
0. **NVF-E017 (VSS)**: la instantánea VSS se borra siempre al terminar (`defer deleteVssSnapshot`).
0. **NVF-E016 (watchdog)**: todo comando externo pasa por `runLoggedCommandEx` (inactividad y tiempo máximo) y es visible en la UI (`/api/log`, "Registro en vivo").
0. **NVF-E018/E019 (verificación)**: un fallo de `bcdboot` es fatal; los demás pasos se juntan en `StepWarnings` y el mensaje final nunca dice "100 %" si alguno falló.
0. **NVF-E022 (sin copia en vivo)**: nunca clonar `\\.\C:` montado ni suponer tamaños; sin VSS o sin tamaño → abortar antes de tocar el destino.
0. **NVF-E023/E024 (identidad)**: antes de `clean` comprobar la identidad física del destino (≠ origen); antes de escribir, comprobar que W: está en el disco destino y mide ≥ C:.
0. **NVF-E025/E026/E029 (verificación)**: los primeros 256 clústeres se juzgan contra la copia exacta de lo escrito (`verifyBootRegion`; solo `$Boot` fuera del BPB puede diferir en la instantánea por BitLocker); el 100 % de lo copiado se relee del destino y se compara con las huellas XxHash64 de lo escrito (`verifyTargetAgainstDigests`); diferencia = error fatal. Prohibido releer la instantánea para validar el resto (pagefile/hiberfil/área VSS no tienen COW) y prohibido saltar diferencias por nombre de archivo.
0. **NVF-E027 (bloqueo)**: nunca escribir sectores en W: sin `FSCTL_LOCK_VOLUME` confirmado; si no se logra, abortar antes de escribir.
0. **NVF-E028 (E/S)**: toda E/S cruda pasa por `positionedIo` (reintentos + `IO_ERROR` con offset y `GetLastError`).
0. **NVF-E030 (letras)**: S:/R: se liberan con `defer releaseCloneLetters` en toda salida tras `dp_init`; dueño de una letra = extents o `QueryDosDeviceW` contra `Harddisk<destino>PartitionN`.
0. **NVF-E031 (no reclonar)**: un clon terminado lleva `W:\NVMeForge_CLON_OK.txt`; con esa marca NVMeForge no toca el disco.
0. **NVF-E032 (API local)**: toda acción es `POST` con `X-NVMeForge: 1`, `Host` 127.0.0.1:8999 y `Origin` propio (`requestAllowed`); nunca acciones por `GET`.
0. **NVF-E033 (proceso)**: el servidor sale solo sin ventana (`idleExitWatchdog`), nunca durante clonación o benchmark.
0. **NVF-E034 (datos reales)**: la interfaz solo muestra lo que Windows mide; lo desconocido es `null` / "No disponible". Prohibidos valores por defecto inventados (velocidades, temperaturas, tamaños) y recursos de Samsung Magician o de internet.
0. **NVF-E035 (identidad confirmada)**: solo se borra el disco que el usuario confirmó (modelo + tamaño exactos en `start-clone`); `start-clone` exige administrador y nunca arranca solo tras un UAC.
0. **NVF-E036 (condiciones)**: no empezar en batería < 60 % ni con C: < 10 GB libres; un dato desconocido es `null`, nunca un valor inventado.
0. **NVF-E037 (registros)**: cada corrida conserva su registro en `logs\runs` (últimas 20); nunca borrar el registro de una corrida anterior.
0. **NVF-E038 (discos)**: nunca suponer números de disco, de partición ni modelos. Destino = el que eligió y confirmó el usuario (`disk=N` + modelo + tamaño, `--target=N` en línea de comandos); origen = disco de C:; EFI y WinRE se buscan por tipo GPT; el tamaño mínimo se calcula (`planClone`). Con varios discos posibles, no se preselecciona ninguno.
0. **NVF-E039 (letras huérfanas)**: una letra solo bloquea si lo que la usa existe. Huérfana = `\\.\X:` no abre (2/3) y su `\Device\...` tampoco existe → se le quita solo el nombre (`freeOrphanLetter`). Todo lo que puede detener la corrida se muestra antes en "Antes de clonar".
0. **Código abierto**: todo archivo de código lleva la cabecera GPL; nunca publicar `_privado\`, `*.bak*`, `bin\` ni `dist\` (ver `.gitignore`); los binarios oficiales los compila GitHub Actions.
0. **NVF-E021 (externo)**: las ventanas "Elegir una aplicación" vinieron de un `pwsh` de otra herramienta con `$_` perdido, no de NVMeForge.

Errores históricos:

1. **Error `❌ Error de Seguridad: Disco #1 no detectado` (`IOCTL_DISK_GET_LENGTH_INFO` `0x0007405C`)** — NVF-E001:
   - **Causa**: `0x0007405C` tiene activo el bit `FILE_READ_ACCESS`. Abrir `\\.\PhysicalDrive1` con `dwDesiredAccess = 0` devuelve `ERROR_ACCESS_DENIED (5)` incluso con Admin.
   - **Regla permanente**: En `getVolumeLengthBytes` (`src\nvmeforge_engine.zig`), abrir primero con `GENERIC_READ` (`0x80000000`) + `IOCTL_DISK_GET_LENGTH_INFO`, y usar como respaldo sin Admin `dwDesiredAccess = 0` + `IOCTL_DISK_GET_DRIVE_GEOMETRY_EX` (`0x000700A0`), leyendo el `u64` de tamaño en `geom_buf[24..32]`.
2. **Error de Ícono Antiguo (`GACO NVMe`) y Validación Binaria `.ico` (9 Resoluciones)**:
   - **Causa**: El `.ico` copiado tenía renderizado el texto `"GACO"` en los píxeles y la caché del perfil mantenía el icono viejo.
   - **Regla permanente**: `assets\app.ico` y `src\assets\nvmeforge.ico` contienen las 9 capas exactas (`16, 20, 24, 32, 40, 48, 64, 128, 256` px) con el emblema **`FORGE` / `NVMe`**, donde `< 256px` son DIB BGRA de 32 bits con `biHeight = sz * 2`, esquinas transparentes (`pad >= 18 * scale`, `alpha = 0`) y máscara `AND` de 1 bit sincronizada con `alpha == 0`, y `256px` es PNG de 32 bits con esquinas transparentes.
3. **Error de Alerta `127.0.0.1:8999 dice` (`window.confirm`)**:
   - **Causa**: `window.confirm()` del navegador muestra el encabezado `127.0.0.1:8999 dice`.
   - **Regla permanente**: Prohibido usar `confirm()` o `alert()`; se utiliza el modal nativo integrado `nvmeforgeConfirmModal` en `src\ui.html`.
4. **Error de Bloqueo por Socket Preconnect de Chromium y `stream.read()`**:
   - **Causa**: En Zig 0.15.2 sobre Windows, `stream.read()` invoca `ReadFile` sin `OVERLAPPED` y falla; además, atender `server.accept()` en un solo hilo se bloquea cuando Chromium abre un socket *preconnect* vacío.
   - **Regla permanente**: Usar siempre `stream.reader(&.{})` (`WSARecv` Overlapped) y despachar cada conexión aceptada en un hilo independiente (`clientWorker`).
5. **Error de Heurística Estática bajo Smart App Control (`SAC State: 1`)**:
   - **Causa**: Incluir literales `--no-sandbox` junto a rutas de navegador, importar `recv`/`send` crudos en la IAT o usar `Set-AuthenticodeSignature` con certificados autofirmados contamina el registro MFT y dispara `CodeIntegrity 3077`.
   - **Regla permanente**: Eliminar el binario previo antes de emitir para renovar el registro MFT y mantener `NotSigned` limpio heredado de `zig.exe`.

## v3.0.0 (salud y rendimiento)
- `src/diskcheck.zig`: salud NVMe ampliada, Identify, TRIM, caché, enlace PCIe, energía y el banco de 4 pruebas. Se importa desde el motor; `zig build` enlaza setupapi, cfgmgr32, powrprof y advapi32.
- El banco solo escribe dentro de su archivo temporal (DELETE_ON_CLOSE) y nunca libera memoria con E/S pendiente. Clon y banco se excluyen con `g_clone_running` / `g_bench_running` (cada lado pone su bandera y luego revisa la del otro).
- Los textos de calor solo afirman lo que registra el disco: los contadores de frenadas del log NVMe cuentan solo el control térmico del host (HCTM).
