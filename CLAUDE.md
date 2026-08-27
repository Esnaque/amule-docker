# aMule 3 on Docker

Docker Compose stack to run aMule 3.0.1 (amuled + amuleweb) on a server.
This is not the aMule source code: just the Docker packaging.

## Architecture

- `Dockerfile` — multi-stage; builds aMule from `https://github.com/amule-org/amule`
  with CMake on debian:trixie-slim. Build args: `AMULE_REPO`, `AMULE_VERSION`
  (a tag like `3.0.1` or a branch like `master` — anything `git clone --branch`
  takes) and `AMULE_GIT_REFRESH` (cache buster; the clone layer is cached, so
  without changing it a branch build keeps recompiling the first commit it
  cloned). The resolved repo/ref/commit is written to `/etc/amule-build-info`
  in the runtime image. All three come from `.env` via compose `build.args`,
  and `AMULE_IMAGE_TAG` names the resulting image.
  It must be trixie: aMule 3 requires wxWidgets with `wxUSE_WEBREQUEST=1` (libcurl
  backend) and bookworm's wx doesn't ship with it enabled.
  Binaries: amuled, amuleweb, amulecmd, and amuleapi when the source has it
  (`-DBUILD_AMULEAPI=ON`; the option only exists in master, 3.0.1 ignores it
  with a "manually-specified variable was not used" warning, so the ldd check
  treats that binary as optional). NOTE: the `amule-project/amule` repo is
  frozen; the right one is `amule-org/amule`.
  Two 3.0.1-specific configure flags: `-DENABLE_IP2COUNTRY=NO` (defaults to ON
  in 3.0.1 and hard-fails without libmaxminddb; the country flags are GUI-only,
  neither amuled nor the WebUI use them) and `-DDEFAULT_VERSION_CHECK=OFF`
  (upstream's packager recommendation; only seeds `[eMule] NewVersionCheck`).
- `entrypoint.sh` — a single entrypoint with roles (`amuled` | `amuleweb` |
  `amuleapi`):
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
  - All chowns go through `try_chown` (best-effort: they only WARN), because on
    NFS/CIFS `chown` returns EPERM even for root and aborting under `set -e`
    turned into a restart loop. Writability is what's enforced instead:
    `check_writable` probes `/config`, `/temp` and `/incoming` with a real
    `touch` as the amule user and exits with an actionable message.
  - amuleweb role: waits until amuled answers over EC and launches
    `amuleweb --host=amuled ...` with plaintext passwords (the hash goes in the
    conf, the CLI wants plaintext).
  - amuleapi role (master-only binary; the new web UI + REST API): writes
    `/config/amuleapi.conf` — a *separate* file from amule.conf, with the EC
    password in CLEARTEXT because amuleapi deliberately has no `--password`
    flag (argv is world-readable via `ps`), which is also why it hard-fails
    unless that file is mode 0600, so every write is followed by a `chmod`.
    Then `--set-admin-pass`/`--set-guest-pass` (they write
    `/config/amuleapi-passwords` and exit, so re-running them each start is
    fine) and launches with `--bind=0.0.0.0` (the default 127.0.0.1 is
    unreachable from outside the container, and amuleapi refuses any other
    bind without an admin password — hence `AMULEAPI_ADMIN_PASSWORD` is
    mandatory). Warns when the EC password contains `$`: amuleapi reads the
    conf with wxFileConfig and doesn't disable `$VAR` expansion.
- `docker-compose.yml` — services `amuled`, `amuleweb`, `amuleapi` (same
  `amule:${AMULE_IMAGE_TAG}` image, different `command`) and `autoheal` (Docker doesn't restart unhealthy
  containers; autoheal does, via the `autoheal=true` label). `amuleapi` sits
  behind `profiles: ["amuleapi"]` so a 3.0.1 image — which has no such binary —
  doesn't crash-loop; it's enabled with `COMPOSE_PROFILES=amuleapi` in `.env`.
  It mounts `/config` (amuleapi keeps its conf, passwords and jwt secret beside
  amuled's) and healthchecks `/api/v0/health`, which needs no login.
- `.env` / `.env.example` — all variables; `SECTION__KEY` vars reach the
  containers via `env_file`, and compose additionally interpolates `EMULE__PORT`,
  `EMULE__UDPPORT` and `WEBSERVER__PORT` into the port mappings, plus the
  `AMULE_VERSION`/`AMULE_REPO`/`AMULE_GIT_REFRESH`/`AMULE_IMAGE_TAG` build
  knobs and `AMULEAPI_PORT` (single source of truth). Variables aimed at the
  entrypoint rather than at amule.conf deliberately avoid `__`
  (`AMULEWEB_TEMPLATE`, `AMULEAPI_ADMIN_PASSWORD`, `CATEGORY_N_*`), otherwise
  they'd be written into amule.conf as a `[Section] Key`.
- Docs: `README.md` (English) and `README.es.md` (Spanish) — keep both in sync
  when changing user-facing behavior. Licensed under GPL-2.0 (`LICENSE`).

## Non-obvious details

- `EXTERNALCONNECT__ECPASSWORD` is mandatory: amuled 3 refuses to start without
  an EC password.
- `[WebServer] Enabled=0` in the seed is intentional: if it were 1, amuled would
  launch its own amuleweb inside the container; here amuleweb is a separate
  service. Same reasoning for `[AmuleApi] Enabled`, which defaults to 0 in
  aMule and must stay there — leave it alone.
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
