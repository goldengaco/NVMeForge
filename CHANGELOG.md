# Cambios

## 3.1.0 — 2026-11-01

- **Tamaño de la prueba:** 1 GiB (como CrystalDiskMark), 4 o 16 GiB. Las pasadas duran 5 s, así que un archivo más grande reparte las pruebas en más zona del disco (menos ayuda de sus cachés); no alarga las escrituras. El historial guarda el tamaño (columna 17; versiones anteriores a la 3.1 ignoran esas filas).
- **Copiar resultados:** texto con disco, conexión, firmware, las 8 velocidades, temperatura, energía y hora de la medición, para pegar en un chat, foro o reseña.
- **Historial de salud por día:** cada día que se abre NVMeForge se guarda una fila por disco (vida usada, datos escritos y leídos, horas, temperatura, minutos calientes, frenadas, errores) en `logs\health_history.tsv`. Discos muestra los últimos 7 días y cuánto se escribe por día (desde el segundo día).
- Revisión independiente: la etiqueta "velocidad sostenida" decía más de lo que mide (cambiada), caché de días que se llenaba, series largas, recarga del historial, barra de progreso con archivos grandes, fecha de la medición al copiar, pruebas que escribían en el historial real. Corregido.

## 3.0.1 — 2026-11-01

Más robusto, a partir del primer clon real con la 2.9.2.

- **Letras devueltas (NVF-E044):** antes de quitar las letras del disco destino se anotan; si la corrida se detiene antes de borrar ese disco (sin letras libres, diskpart falla al empezar), se le devuelven.
- **TRIM del disco nuevo:** al terminar la copia se optimiza el Windows del clon (`defrag W: /L`, lo mismo que "Optimizar unidades"), para que el disco no cargue bloques de un clon anterior. Si el adaptador USB no deja pasar TRIM, solo queda en el registro.
- **Registro en el disco nuevo:** antes del mensaje final, el registro completo de la clonación se copia al Windows del clon (misma carpeta `%TEMP%\NVMeForge\logs`) y se escribe al disco. Así se sabe cuánto tardó aunque el disco viejo ya no esté.
- **Tiempo estimado real:** `clones.tsv` guarda la duración y los bytes de cada clon; "Antes de clonar" estima con tu clon anterior en vez de la prueba rápida de solo lectura (que en discos vacíos sale inflada). El tiempo restante durante el clon cuenta el paso de TRIM.
- Revisión independiente: las letras devueltas no deben volver a quitarse en la salida por error; el estimado compara lo mismo (C: usado + particiones extra); el registro se copia antes de decir "ya puede apagar". Corregido.

## 3.0.0 — 2026-10-31

Salud y rendimiento completos, para saber si el disco nuevo rinde lo que pagaste sin instalar otros programas.

- **Discos (F10):** conexión PCIe real del disco (generación y carriles, actual y máxima), estándar NVMe, TRIM, caché de escritura y su vaciado, minutos sobre la temperatura de aviso y crítica, frenadas por calor registradas por el control térmico del disco y su tiempo, cada sensor de temperatura y un **Diagnóstico** con qué hacer en cada punto. Todo sale del log de salud NVMe y de consultas de Windows; nada se cambia.
- **Rendimiento (F11):** las 4 pruebas de CrystalDiskMark (SEQ1M Q8T1, SEQ1M Q1T1, RND4K Q32T1, RND4K Q1T1), lectura y escritura, con 1, 3 o 5 pasadas de 5 s. Se hacen sobre un archivo oculto de 1 GiB (`X:\NVMeForge-prueba.tmp`) con datos aleatorios que Windows borra al cerrarlo aunque NVMeForge se cierre a la fuerza; si quedó uno por un apagón, se borra al abrir NVMeForge. Nunca escribe en el disco en bruto. Muestra la velocidad en vivo, la temperatura y si el disco se calentó de más mientras mide, un **Veredicto** contra el límite real de su conexión PCIe, los **ajustes de Windows** que cambian la medición (cargador, modo o plan de energía, ahorro de PCI Express, TRIM) y un historial. Se puede cancelar.
- La prueba anterior (solo lectura en bruto) queda como "Prueba rápida de solo lectura" para discos sin letra, con la advertencia de que en zonas nunca escritas sale más alta que la realidad.
- No se puede clonar mientras corre una prueba ni probar mientras se clona (cada lado pone su bandera y luego revisa la del otro).
- Revisión independiente antes de entregar: carrera clon/prueba al mismo tiempo, esperar siempre a que termine toda E/S antes de liberar memoria, textos de calor que decían más de lo que mide el disco (los contadores de frenadas solo cuentan el control térmico del host), texto de caché, modo de energía en planes que no son Equilibrado, sensores con hueco, Identify consultado en cada refresco, unidades GiB. Todo corregido.

## 2.9.2 — 2026-10-31

- **"Quiero reclonarlo":** un disco que ya tiene un clon terminado (NVF-E031) se puede desbloquear desde la interfaz con dos clics; solo se borra la marca de ese disco.

## 2.9.1 — 2026-10-30 (noche)

- **"Qué sigue" (F9):** al terminar un clon (bien o con avisos) aparece la lista de pasos para cambiar el disco (apagar, clave de BitLocker, cambiar el NVMe, F9 si no arranca, revisar el tamaño de C:, reactivar BitLocker, guardar el disco viejo), con casillas que se recuerdan.
- **Aviso al terminar:** cambia el título de la ventana, suena un tono (se puede apagar en "Sonido al terminar") y sale una notificación de Windows si le diste permiso al confirmar el clon.

## 2.9.0 — 2026-10-30 (noche)

Mejoras a partir del primer clon completo real (2.8.0: 25 min, 0 diferencias).

- **Más rápido (F1):** la lectura y la escritura se hacen al mismo tiempo (lectura adelantada en 4 bloques de 8 MiB), también en la relectura; no se copian `pagefile.sys`, `hiberfil.sys` ni `swapfile.sys` (Windows los recrea; se copia su primer MiB y se borran del clon, y se avisa si no se pudieron borrar); se quitó el `chkdsk /scan` final (chkdsk /f ya corre tras la copia verificada).
- **Progreso real (F2):** un solo porcentaje de todo el clon, GB copiados y releídos, y tiempo restante en todas las etapas (antes salía "—" y se quedaba en 93 %).
- **Revisión del arranque (F3):** al terminar comprueba que existen los archivos de arranque y que el arranque del disco nuevo (`bcdedit /store`) apunta a su propio Windows.
- **Letras automáticas (F4):** usa S, W, R, Z e Y si están libres y, si no, otras letras libres; una letra ocupada ya no detiene el clon. Antes de cada paso comprueba que la letra sigue en el disco correcto (si una memoria USB la tomó durante la copia, no se escribe en ella).
- Revisión independiente antes de entregar: guardas por letra en cada paso, registro protegido entre hilos, plantillas de letras comprobadas al compilar.

## 2.8.0 — 2026-10-30

- **Clon completo:** además de C:, se copian todas las demás particiones del disco de origen (por ejemplo las de herramientas y restauración del fabricante), con su mismo tipo, atributos y tamaño, al final del disco nuevo. C: crece hasta llenar el resto. Cada una se copia sector por sector y se relee el 100 % comparando huellas XxHash64 de lo escrito.
- Una partición extra con letra (en uso, por ejemplo una D:) no se copia en esta versión y se avisa en "Antes de clonar".
- **Tamaño de sector (NVF-E040):** si el origen y el destino usan distinto tamaño de sector lógico (512 contra 4096), se detiene antes de tocar nada.
- Si una partición extra no se puede copiar o verificar, el clon termina con advertencia (NVF-E041) y lo dice.
- "Antes de clonar" muestra qué particiones se copian y el tamaño de sector de ambos discos.

## 2.7.1 — 2026-10-30

- **Letras huérfanas (NVF-E039):** la primera corrida de la 2.7.0 se detuvo con "Letra S: ocupada por otro dispositivo", pero S: no era de ningún disco: quedó de una partición que ya no existe (en el Explorador, "Disco local (S:)" sin tamaño). Ahora NVMeForge reconoce esas letras (la letra no abre y el dispositivo al que apunta tampoco existe) y les quita solo el nombre antes de seguir. Si Windows no lo deja, dice exactamente qué hacer (reiniciar o `mountvol S: /D`).
- **Antes de clonar muestra las letras:** nueva comprobación "Letras que usa NVMeForge" (S:, W:, R:, Z:, Y:): una letra huérfana es un aviso; una letra de otro disco bloquea y dice cuál es ("la usa el disco 0 (modelo)"). Así el problema se ve antes de confirmar, no a mitad de la corrida.
- El error NVF-E009 dice qué disco usa la letra en vez de mandar a PowerShell.

## 2.7.0 — 2026-10-30

Primera versión preparada para publicarse como código abierto.

- **Cualquier disco destino (NVF-E038):** el destino ya no es siempre el "disco 1". Lo eliges en pantalla; con un solo disco además del de Windows se preselecciona, con varios (por ejemplo varios adaptadores USB) NVMeForge no adivina. Cada opción muestra número, modelo, tamaño, conexión y serie. Por línea de comandos: `--clone --target=N`.
- **Cualquier disco de origen:** el origen es el disco donde está C:, no el "disco 0". La partición EFI y la de recuperación se buscan por su tipo GPT, no por número.
- **Tamaño mínimo real (NVF-E001):** ya no se exigen 1.5 TB. El mínimo se calcula: C: + EFI + MSR + recuperación + margen. Si la EFI o la recuperación de origen son más grandes que 260 MiB / 1000 MiB, el clon las crea del mismo tamaño.
- **EFI del fabricante:** se conservan todas sus carpetas (HP, Dell, Lenovo…), no solo `\EFI\HP`.
- **Corre en cualquier PC con Windows 11:** el ejecutable apunta a x86-64-v2 (antes solo AMD Zen 4).
- **Código abierto:** licencia GPL-3.0-or-later, sin logotipos de marcas, información de versión dentro del `.exe`, compilación y pruebas en GitHub Actions, política de firma y de seguridad.
- Mensajes sin modelos ni marcas fijos ("Samsung", "UGREEN", "Disco #1").
- La ventana y el progreso guardan sus archivos en `%TEMP%\NVMeForge`.

## 2.6.1 — 2026-10-30

Registro limpio en cada sesión; las corridas anteriores quedan en `logs\runs`.

## 2.6.0 — 2026-10-30

Temperatura y vida restante, "100 % clonado" y cambios de C: desde el clon (diario USN), selector de corridas, cuatro temas.

## 2.5.0 — 2026-10-30

Confirmación de modelo y tamaño exactos del destino (NVF-E035), batería y espacio libre antes de empezar (NVF-E036), historial de registros (NVF-E037).

## 2.4.0 — 2026-10-30

Interfaz nueva solo con datos reales (NVF-E034), API local protegida (NVF-E032), cierre del proceso al cerrar la ventana (NVF-E033).

## 2.3.x — 2026-10-30

Verificación del 100 % de lo escrito con huellas XxHash64 (NVF-E026), bloqueo exclusivo del destino (NVF-E027), reintentos de E/S (NVF-E028), protección del clon terminado (NVF-E031), liberación de letras (NVF-E030).

El detalle de cada error y su corrección está en [ERROR_CATALOG.md](ERROR_CATALOG.md).
