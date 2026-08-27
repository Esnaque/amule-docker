# aMule 3 en Docker (amuled + amuleweb)

[English](README.md) | **Español**

Stack de Docker Compose que compila [aMule](https://github.com/amule-org/amule)
(3.0.1 por defecto, [cualquier tag o rama](#qué-versión-de-amule-se-compila))
desde el código fuente y levanta:

- **amuled** — el daemon de aMule (redes eD2k y Kad)
- **amuleweb** — la interfaz web, conectada a amuled por External Connections (EC)
- **autoheal** — reinicia automáticamente cualquier contenedor cuyo healthcheck falle
  (Docker no lo hace por sí solo)

> Nota: el desarrollo de aMule continúa en `amule-org/amule`;
> el repo antiguo `amule-project/amule` está congelado.

## Uso

```sh
cp .env.example .env   # edita las contraseñas como mínimo
docker compose up -d --build
```

Interfaz web: http://localhost:4711 (contraseña: `WEBSERVER__PASSWORD`).

## Qué versión de aMule se compila

La imagen se compila desde el código fuente, y `.env` decide qué código:

```
AMULE_VERSION=3.0.1        # un tag de release...
AMULE_IMAGE_TAG=3.0.1      # ...y el tag que se le pone a la imagen construida
```

Para seguir el desarrollo de upstream en vez de una release, apúntalo a una rama:

```
AMULE_VERSION=master
AMULE_IMAGE_TAG=master
AMULE_GIT_REFRESH=2026-08-27
```

- `AMULE_VERSION` admite cualquier cosa que acepte `git clone --branch`: un tag
  o una rama.
- `AMULE_IMAGE_TAG` sólo da nombre a la imagen local. Cámbialo junto con
  `AMULE_VERSION` para que un build de master no pise tu imagen de release y
  puedas volver atrás cambiando el tag y haciendo `docker compose up -d`.
- `AMULE_GIT_REFRESH` es un **invalidador de caché**, necesario sólo con ramas:
  la capa del `git clone` se cachea como cualquier otra, así que sin cambiar
  este valor cada rebuild compilaría el mismo commit que clonó la primera vez.
  Ponle la fecha de hoy (o cualquier valor nuevo) cuando quieras traer commits
  nuevos. `docker compose build --no-cache amuled` también sirve, pero además
  recompila todo lo demás desde cero.
- `AMULE_REPO` (opcional) cambia el repositorio, por si compilas un fork.

De qué commit se construyó una imagen queda registrado dentro de ella:

```sh
docker exec amuled cat /etc/amule-build-info
```

Compilar master es compilar código sin probar: guarda una copia de tu carpeta
`/config` antes de cambiar, porque un aMule más nuevo puede reescribir
`amule.conf` de formas que el build de release ya no sepa leer.

## La interfaz web nueva (amuleapi)

aMule master incluye **amuleapi**, un daemon aparte que sirve una API REST
JSON, un stream de eventos en vivo y —lo que se ve— una interfaz web nueva en
su propio puerto. Upstream da amuleweb por obsoleto en favor suyo («may be
removed in aMule 3.2 or later»), pero aquí conviven, así que puedes quedarte
con la vieja mientras pruebas la nueva.

Sólo existe en master, así que hacen falta dos cosas: compilar master y activar
el perfil de compose que levanta el contenedor.

```
AMULE_VERSION=master
AMULE_IMAGE_TAG=master
AMULE_GIT_REFRESH=2026-08-27
COMPOSE_PROFILES=amuleapi
AMULEAPI_ADMIN_PASSWORD=cambiame
```

```sh
docker compose up -d --build
```

La interfaz nueva queda en http://localhost:4713 y la vieja sigue en
http://localhost:4711.

- `AMULEAPI_ADMIN_PASSWORD` es **obligatoria**: amuleapi se niega a escuchar en
  algo que no sea `127.0.0.1` mientras no haya contraseña de admin, y dentro de
  un contenedor tiene que escuchar en `0.0.0.0` para ser accesible.
- `AMULEAPI_GUEST_PASSWORD` (opcional) habilita un acceso de invitado de sólo
  lectura. Sin ella, el acceso de invitado queda desactivado.
- `AMULEAPI_PORT` (por defecto 4713) cambia el puerto.
- Las contraseñas se guardan con sal y stretching en
  `/config/amuleapi-passwords` y no se pueden leer, sólo reemplazar — el
  entrypoint las reescribe desde `.env` en cada arranque.
- Evita el `$` en `AMULEAPI_ADMIN_PASSWORD` y `EXTERNALCONNECT__ECPASSWORD`: la
  contraseña EC tiene que guardarse en claro en `/config/amuleapi.conf`
  (amuleapi no tiene flag `--password` a propósito: argv lo ve cualquiera con
  `ps`), y el lector expande `$VAR` en los valores. El entrypoint avisa si
  encuentra uno.
- Sin `COMPOSE_PROFILES=amuleapi` el servicio ni se arranca, así que una
  instalación normal de 3.0.1 no se ve afectada. Una imagen de 3.0.1 no tiene
  el binario amuleapi; si aun así levantas el servicio, sale con un error
  explicativo en vez de quedarse reiniciándose en bucle.

Como amuleweb, es HTTP sin TLS: vale para una LAN de confianza; si no, ponle
un proxy inverso delante.

## Configuración por variables de entorno

Cualquier variable del `.env` con el formato `SECTION__KEY` se vuelca a
`amule.conf` en cada arranque del contenedor:

```
EMULE__MAXUPLOAD=100        ->  [eMule] MaxUpload=100
WEBSERVER__PASSWORD=secreto ->  [WebServer] Password=<md5>
```

- La coincidencia con secciones/claves ya presentes en `amule.conf` es
  case-insensitive (se conserva la grafía del archivo).
- Si la clave no existe aún, se crea con la grafía de la variable; para esas
  usa la grafía exacta de aMule (p. ej. `eMule__SmartIdCheck=1`), porque el
  formato de configuración distingue mayúsculas.
- Las contraseñas (`WEBSERVER__PASSWORD`, `WEBSERVER__PASSWORDLOW`,
  `EXTERNALCONNECT__ECPASSWORD`) se escriben en plano en el `.env` y el
  entrypoint las convierte al hash MD5 que aMule espera.

Variables obligatorias: `EXTERNALCONNECT__ECPASSWORD` y `WEBSERVER__PASSWORD`.

## Categorías de descarga

Las categorías (cada una con su carpeta de destino) se definen con variables
`CATEGORY_<N>_*`, numeradas correlativamente desde 1:

```
CATEGORY_1_TITLE=Movies
CATEGORY_1_INCOMING=/incoming/movies
CATEGORY_2_TITLE=TV Shows
CATEGORY_2_INCOMING=/incoming/tvshows
```

- `TITLE` e `INCOMING` son obligatorias por categoría; `COLOR`, `PRIORITY` y
  `COMMENT` son opcionales (en aMule 3 la clave es `Color`, no `Colour`).
- `INCOMING` es una ruta **dentro del contenedor**: usa subcarpetas de
  `/incoming` o monta volúmenes extra en el compose
  (p. ej. `- /mnt/nas/video/movies:/incoming/movies`).
- El entrypoint crea las carpetas si no existen y escribe las secciones
  `[Cat\#N]` y el `Count` de `[General]` en `amule.conf` en cada arranque.
- Si quitas las variables del `.env`, las categorías ya escritas en
  `amule.conf` se conservan (igual que el resto de overrides); bórralas desde
  la interfaz o reduce a mano el `Count`.

## Volúmenes

| Variable             | Contenedor  | Contenido                          |
| -------------------- | ----------- | ---------------------------------- |
| `AMULE_CONFIG_DIR`   | `/config`   | `amule.conf`, claves, estadísticas |
| `AMULE_INCOMING_DIR` | `/incoming` | descargas completadas              |
| `AMULE_TEMP_DIR`     | `/temp`     | descargas en curso (.part)         |

`AMULE_TEMP_DIR` tiene que apuntar a un directorio **dedicado**, nunca a uno
compartido como el `/tmp` del host: el entrypoint hace `chown` recursivo de
`/temp`, lo que regalaría todos los ficheros que hubiera dentro a
`PUID`:`PGID`. Mantenlo además en disco local: los `.part` reciben escrituras
constantes y en un recurso de red eso es lento y frágil.

Las rutas de `CATEGORY_*_INCOMING` son rutas **dentro del contenedor** (p. ej.
`/incoming/movies`), no del host. Una categoría que apunte fuera de `/incoming`
necesita su propio bind mount, o sus descargas acaban en la capa de escritura
del contenedor y se pierden al recrearlo — el entrypoint avisa cuando lo
detecta.

## Puertos

| Puerto   | Protocolo | Servicio | Uso                                    |
| -------- | --------- | -------- | -------------------------------------- |
| 4662     | TCP       | amuled   | eD2k (ábrelo/redirígelo en el router para tener ID alta) |
| 4672     | UDP       | amuled   | Kad y extended server requests         |
| 4711     | TCP       | amuleweb | interfaz web antigua                   |
| 4713     | TCP       | amuleapi | interfaz web nueva + API REST (builds de master, `COMPOSE_PROFILES=amuleapi`) |
| 4712     | TCP       | amuled   | EC — interno; descomenta el mapeo en el compose solo si quieres usar amulegui remoto |

## Healthchecks

- **amuled**: `amulecmd -c status` contra el puerto EC.
- **amuleweb**: `curl` a la propia interfaz web.
- **amuleapi**: `curl` a `/api/v0/health`, que no necesita login y responde sin
  depender de amuled.

Si un healthcheck falla 3 veces seguidas el contenedor pasa a `unhealthy` y
autoheal lo reinicia.

## Permisos

Los procesos corren como el usuario `amule` con el `PUID`/`PGID` del `.env`
(por defecto 1000:1000). El entrypoint hace `chown` recursivo de `/config` y
`/temp`, y no recursivo de `/incoming` (puede ser enorme); si migras un
`/incoming` existente con otro propietario, ajusta los permisos a mano.

Esos `chown` son best-effort. En sistemas de archivos de red (NFS con
`root_squash`, CIFS con opciones `uid`/`gid`) `chown` falla con `Operation not
permitted` incluso siendo root; el entrypoint registra un `WARN` y continúa.
Lo que sí exige es que el usuario `amule` pueda escribir de verdad en
`/config`, `/temp` e `/incoming`: comprueba cada uno y sale con un error
explícito si no puede. Si te topas con ese error, pon `PUID`/`PGID` al
propietario del directorio del host (`stat -c '%u:%g' /tu/incoming`) en lugar
de hacer `chown` al recurso compartido.

## Licencia

[GPL-2.0](LICENSE), la misma que aMule.
