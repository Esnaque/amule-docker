# aMule 3 on Docker

Docker Compose stack to run aMule 3.0.1 (amuled + amuleweb) on a server.
This is not the aMule source code: just the Docker packaging.

## Architecture

- `Dockerfile` — multi-stage; builds aMule 3.0.1 from `https://github.com/amule-org/amule`
  (tag `3.0.1`, args `AMULE_REPO`/`AMULE_VERSION`) with CMake on debian:trixie-slim.
  It must be trixie: aMule 3 requires wxWidgets with `wxUSE_WEBREQUEST=1` (libcurl
  backend) and bookworm's wx doesn't ship with it enabled.
  Binaries: amuled, amuleweb, amulecmd. NOTE: the `amule-project/amule` repo is
  frozen; the right one is `amule-org/amule`.
  Two 3.0.1-specific configure flags: `-DENABLE_IP2COUNTRY=NO` (defaults to ON
  in 3.0.1 and hard-fails without libmaxminddb; the country flags are GUI-only,
  neither amuled nor the WebUI use them) and `-DDEFAULT_VERSION_CHECK=OFF`
  (upstream's packager recommendation; only seeds `[eMule] NewVersionCheck`).
- `entrypoint.sh` — a single entrypoint with roles (`amuled` | `amuleweb`):
  - Generates a seed `amule.conf` if it doesn't exist (sections with canonical
    spelling).
  - Writes every `SECTION__KEY` environment variable into `amule.conf`
    (case-insensitive match against existing entries; new keys are created with
    the variable's spelling — wxFileConfig is case-sensitive).
  - Hashes passwords to MD5 (`WebServer/Password`, `WebServer/PasswordLow`,
    `ExternalConnect/ECPassword`) — aMule stores them hashed.
  - Download categories via `CATEGORY_<N>_TITLE`/`_INCOMING` (optional
    `_COLOR`/`_PRIORITY`/`_COMMENT`, consecutive from 1): writes the `[Cat\#N]`
    sections (the `#` is escaped in the file) and `[General] Count` into
    amule.conf, and creates/chowns the target folders. In aMule 3 the key is
    `Color` (old installs wrote `Colour`).
  - Adjusts the `amule` user to `PUID`/`PGID` and execs with gosu.
  - amuleweb role: waits until amuled answers over EC and launches
    `amuleweb --host=amuled ...` with plaintext passwords (the hash goes in the
    conf, the CLI wants plaintext).
- `docker-compose.yml` — services `amuled`, `amuleweb` (same `amule:3.0.0` image,
  different `command`) and `autoheal` (Docker doesn't restart unhealthy
  containers; autoheal does, via the `autoheal=true` label).
- `.env` / `.env.example` — all variables; `SECTION__KEY` vars reach the
  containers via `env_file`, and compose additionally interpolates `EMULE__PORT`,
  `EMULE__UDPPORT` and `WEBSERVER__PORT` into the port mappings (single source
  of truth).
- Docs: `README.md` (English) and `README.es.md` (Spanish) — keep both in sync
  when changing user-facing behavior. Licensed under GPL-2.0 (`LICENSE`).

## Non-obvious details

- `EXTERNALCONNECT__ECPASSWORD` is mandatory: amuled 3 refuses to start without
  an EC password.
- `[WebServer] Enabled=0` in the seed is intentional: if it were 1, amuled would
  launch its own amuleweb inside the container; here amuleweb is a separate
  service.
- Healthchecks use `$$VAR` in the compose file so the expansion happens inside
  the container (vars arrive via env_file), not at compose interpolation time.
- EC port 4712 is not published to the host by default (compose-internal
  network only).
- Volumes: `/config`, `/incoming`, `/temp` mapped from the `.env` `AMULE_*_DIR`
  vars. The `/incoming` chown is non-recursive on purpose (it can be huge).
- `.env` (passwords) and `data/` (runtime state and downloads) are gitignored —
  never commit them.

## Commands

```sh
docker compose up -d --build        # bring everything up
docker compose logs -f amuled       # daemon logs
docker exec amuled amulecmd -h 127.0.0.1 -P <ecpass> -c status   # status via EC
```
