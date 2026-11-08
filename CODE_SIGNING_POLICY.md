# Code signing policy / Política de firma de código

> **Estado:** solicitud a SignPath Foundation pendiente. Hasta que se apruebe, las versiones publicadas no están firmadas y Windows puede mostrar un aviso al abrirlas. Al aprobarse se quita esta nota.

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

## Qué se firma

Solo `NVMeForge.exe` compilado por GitHub Actions ([.github/workflows/build.yml](.github/workflows/build.yml)) a partir del código de este repositorio, en una versión etiquetada (`vX.Y.Z`). Nunca se firman compilaciones hechas a mano en un equipo personal ni binarios de terceros.

## Roles del equipo

- **Committers and reviewers / Autores y revisores:** [miembros de la organización en GitHub](https://github.com/) — *se completa con el enlace al equipo cuando exista la organización.*
- **Approvers / Aprobadores:** Carlos Javier (dueño del repositorio). Cada firma se aprueba a mano en SignPath.

Todos los miembros usan autenticación de dos factores en GitHub y en SignPath.

## Privacy policy / Privacidad

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

NVMeForge no se conecta a internet. Su interfaz es una página local en `127.0.0.1:8999` que solo atiende a su propia ventana.

## Cambios en el sistema y desinstalación

Ver la sección *Privacidad y seguridad* del [README](README.md): qué toca NVMeForge en Windows y cómo quitarlo (borrar el `.exe` y la carpeta `%TEMP%\NVMeForge`).
