# aMule 3 on Docker (amuled + amuleweb)

**English** | [Español](README.es.md)

Docker Compose stack that builds [aMule 3.0.0](https://github.com/amule-org/amule)
from source and runs:

- **amuled** — the aMule daemon (eD2k and Kad networks)
- **amuleweb** — the web interface, connected to amuled over External Connections (EC)
- **autoheal** — automatically restarts any container whose healthcheck fails
  (Docker doesn't do this on its own)

> Note: aMule development continues at `amule-org/amule`;
> the old `amule-project/amule` repo is frozen.

## Usage

```sh
cp .env.example .env   # edit the passwords at the very least
docker compose up -d --build
```

Web interface: http://localhost:4711 (password: `WEBSERVER__PASSWORD`).

## Configuration via environment variables

Any variable in `.env` with the `SECTION__KEY` format is written to
`amule.conf` on every container start:

```
EMULE__MAXUPLOAD=100        ->  [eMule] MaxUpload=100
WEBSERVER__PASSWORD=secret  ->  [WebServer] Password=<md5>
```

- Matching against sections/keys already present in `amule.conf` is
  case-insensitive (the file's spelling is preserved).
- If the key doesn't exist yet, it is created with the variable's spelling;
  for those, use aMule's exact spelling (e.g. `eMule__SmartIdCheck=1`),
  because the configuration format is case-sensitive.
- Passwords (`WEBSERVER__PASSWORD`, `WEBSERVER__PASSWORDLOW`,
  `EXTERNALCONNECT__ECPASSWORD`) are written in plaintext in `.env` and the
  entrypoint converts them to the MD5 hash aMule expects.

Required variables: `EXTERNALCONNECT__ECPASSWORD` and `WEBSERVER__PASSWORD`.

## Download categories

Categories (each with its own target folder) are defined with
`CATEGORY_<N>_*` variables, numbered consecutively from 1:

```
CATEGORY_1_TITLE=Movies
CATEGORY_1_INCOMING=/incoming/movies
CATEGORY_2_TITLE=TV Shows
CATEGORY_2_INCOMING=/incoming/tvshows
```

- `TITLE` and `INCOMING` are required per category; `COLOR`, `PRIORITY` and
  `COMMENT` are optional (in aMule 3 the key is `Color`, not `Colour`).
- `INCOMING` is a path **inside the container**: use subfolders of
  `/incoming` or mount extra volumes in the compose file
  (e.g. `- /mnt/nas/video/movies:/incoming/movies`).
- The entrypoint creates the folders if they don't exist and writes the
  `[Cat\#N]` sections and the `[General]` `Count` into `amule.conf` on every
  start.
- If you remove the variables from `.env`, categories already written to
  `amule.conf` are kept (same as every other override); delete them from the
  interface or lower the `Count` by hand.

## Volumes

| Variable             | Container   | Contents                            |
| -------------------- | ----------- | ----------------------------------- |
| `AMULE_CONFIG_DIR`   | `/config`   | `amule.conf`, keys, statistics      |
| `AMULE_INCOMING_DIR` | `/incoming` | completed downloads                 |
| `AMULE_TEMP_DIR`     | `/temp`     | in-progress downloads (.part)       |

## Ports

| Port     | Protocol  | Service  | Use                                    |
| -------- | --------- | -------- | -------------------------------------- |
| 4662     | TCP       | amuled   | eD2k (open/forward it on your router to get a high ID) |
| 4672     | UDP       | amuled   | Kad and extended server requests       |
| 4711     | TCP       | amuleweb | web interface                          |
| 4712     | TCP       | amuled   | EC — internal; uncomment the mapping in the compose file only if you want to use a remote amulegui |

## Healthchecks

- **amuled**: `amulecmd -c status` against the EC port.
- **amuleweb**: `curl` against the web interface itself.

If a healthcheck fails 3 times in a row the container goes `unhealthy` and
autoheal restarts it.

## Permissions

The processes run as the `amule` user with the `PUID`/`PGID` from `.env`
(default 1000:1000). The entrypoint chowns `/config` and `/temp` recursively,
and `/incoming` non-recursively (it can be huge); if you migrate an existing
`/incoming` with a different owner, fix the permissions by hand.

## License

[GPL-2.0](LICENSE), same as aMule itself.
