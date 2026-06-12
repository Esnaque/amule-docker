# aMule 3 en Docker (amuled + amuleweb)

[English](README.md) | **Español**

Stack de Docker Compose que compila [aMule 3.0.0](https://github.com/amule-org/amule)
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

## Puertos

| Puerto   | Protocolo | Servicio | Uso                                    |
| -------- | --------- | -------- | -------------------------------------- |
| 4662     | TCP       | amuled   | eD2k (ábrelo/redirígelo en el router para tener ID alta) |
| 4672     | UDP       | amuled   | Kad y extended server requests         |
| 4711     | TCP       | amuleweb | interfaz web                           |
| 4712     | TCP       | amuled   | EC — interno; descomenta el mapeo en el compose solo si quieres usar amulegui remoto |

## Healthchecks

- **amuled**: `amulecmd -c status` contra el puerto EC.
- **amuleweb**: `curl` a la propia interfaz web.

Si un healthcheck falla 3 veces seguidas el contenedor pasa a `unhealthy` y
autoheal lo reinicia.

## Permisos

Los procesos corren como el usuario `amule` con el `PUID`/`PGID` del `.env`
(por defecto 1000:1000). El entrypoint hace `chown` recursivo de `/config` y
`/temp`, y no recursivo de `/incoming` (puede ser enorme); si migras un
`/incoming` existente con otro propietario, ajusta los permisos a mano.

## Licencia

[GPL-2.0](LICENSE), la misma que aMule.
