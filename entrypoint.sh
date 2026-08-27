#!/bin/bash
# Entrypoint for amuled, amuleweb and amuleapi.
#
# Configuration via environment variables in the SECTION__KEY format:
#   EMULE__MAXUPLOAD=100        -> [eMule] MaxUpload=100
#   WEBSERVER__PASSWORD=secret  -> [WebServer] Password=<md5(secret)>
#
# Matching against sections/keys already present in amule.conf is
# case-insensitive (the file's original spelling is preserved). If the
# key doesn't exist yet, it is added spelled exactly as the variable,
# so for keys not included in the seed template use aMule's exact
# spelling (e.g. eMule__SmartIdCheck=1), because wxFileConfig is
# case-sensitive.
set -euo pipefail

ROLE="${1:-amuled}"
CONFIG_DIR="${AMULE_HOME:-/config}"
CONF="$CONFIG_DIR/amule.conf"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log() { echo "[entrypoint] $*"; }

md5() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# try_chown <chown args...> <path>
# /incoming, /temp and the category targets often live on network filesystems
# (NFS with root_squash maps root to nobody, CIFS fixes uid/gid at mount time)
# where chown returns EPERM even for root. Ownership is a convenience, not a
# requirement, so warn and carry on instead of aborting under `set -e`.
try_chown() {
    chown "$@" 2>/dev/null \
        || log "WARN: chown failed on ${*: -1} (network filesystem?); leaving ownership as-is"
}

# check_writable <path>
# What actually matters is whether the amule user can write, so probe it for
# real: test -w lies on NFS/CIFS with root_squash or ACLs in play.
check_writable() {
    local path="$1" probe="$1/.amule-write-test.$$"
    if gosu amule touch "$probe" 2>/dev/null; then
        rm -f "$probe"
        return 0
    fi
    log "ERROR: $path is not writable by uid $PUID:$PGID."
    log "       Set PUID/PGID in .env to the owner of the host directory, or fix"
    log "       its permissions / the uid,gid mount options."
    exit 1
}

# set_conf <file> <Section> <Key> <Value>
# Replaces the key within its section (case-insensitive) or appends it;
# creates the section at the end of the file if it doesn't exist.
set_conf() {
    local file="$1"
    AWK_SEC="$2" AWK_KEY="$3" AWK_VAL="$4" awk '
        BEGIN {
            sec = ENVIRON["AWK_SEC"]; key = ENVIRON["AWK_KEY"]; val = ENVIRON["AWK_VAL"]
            sl = tolower(sec); kl = tolower(key)
            insec = 0; done = 0; secfound = 0
        }
        /^\[/ {
            if (insec && !done) { print key "=" val; done = 1 }
            s = $0
            sub(/^\[/, "", s); sub(/\][ \t\r]*$/, "", s)
            insec = (tolower(s) == sl)
            if (insec) secfound = 1
            print; next
        }
        {
            if (insec && !done) {
                eq = index($0, "=")
                if (eq > 0) {
                    k = substr($0, 1, eq - 1)
                    gsub(/[ \t\r]/, "", k)
                    if (tolower(k) == kl) { print k "=" val; done = 1; next }
                }
            }
            print
        }
        END {
            if (!done) {
                if (!secfound) print "[" sec "]"
                print key "=" val
            }
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

seed_config() {
    log "Generating initial amule.conf at $CONF"
    cat > "$CONF" <<'EOF'
[eMule]
Nick=aMule docker
IncomingDir=/incoming
TempDir=/temp
Port=4662
UDPPort=4672
UPnPEnabled=0
MaxUpload=0
MaxDownload=0
ConnectToED2K=1
ConnectToKad=1
[ExternalConnect]
AcceptExternalConnections=1
ECAddress=
ECPort=4712
ECPassword=
UPnPECEnabled=0
[WebServer]
Enabled=0
Password=
PasswordLow=
Port=4711
UseGzip=1
EOF
}

# Applies every SECTION__KEY environment variable to amule.conf.
apply_env_overrides() {
    local name sec key val
    for name in $(compgen -e); do
        [[ "$name" == *__* ]] || continue
        sec="${name%%__*}"
        key="${name#*__}"
        [[ "$sec" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || continue
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || continue
        val="${!name}"
        # Passwords are stored as MD5 hashes in amule.conf
        case "$(tr '[:upper:]' '[:lower:]' <<< "$sec")/$(tr '[:upper:]' '[:lower:]' <<< "$key")" in
            webserver/password|webserver/passwordlow|externalconnect/ecpassword)
                val="$(md5 "$val")"
                log "Applying [$sec] $key=<md5 hash>"
                ;;
            *)
                log "Applying [$sec] $key=$val"
                ;;
        esac
        set_conf "$CONF" "$sec" "$key" "$val"
    done
}

# Download categories via CATEGORY_<N>_TITLE + CATEGORY_<N>_INCOMING
# (optional: _COLOR, _PRIORITY, _COMMENT). aMule 3 stores them in
# amule.conf itself as [Cat\#N] sections (the # is escaped in the file)
# plus [General] Count=N, and only reads 1 through Count, so they must
# be consecutive starting at 1. Paths are paths INSIDE the container.
apply_categories() {
    local n=1 title incoming sec var
    while true; do
        var="CATEGORY_${n}_TITLE";    title="${!var:-}"
        var="CATEGORY_${n}_INCOMING"; incoming="${!var:-}"
        [[ -n "$title" || -n "$incoming" ]] || break
        if [[ -z "$title" || -z "$incoming" ]]; then
            log "ERROR: category $n needs both CATEGORY_${n}_TITLE and CATEGORY_${n}_INCOMING."
            exit 1
        fi
        sec="Cat\\#${n}"
        log "Applying category $n: $title -> $incoming"
        set_conf "$CONF" "$sec" "Title" "$title"
        set_conf "$CONF" "$sec" "Incoming" "$incoming"
        var="CATEGORY_${n}_COLOR";    [[ -n "${!var:-}" ]] && set_conf "$CONF" "$sec" "Color" "${!var}"
        var="CATEGORY_${n}_PRIORITY"; [[ -n "${!var:-}" ]] && set_conf "$CONF" "$sec" "Priority" "${!var}"
        var="CATEGORY_${n}_COMMENT";  [[ -n "${!var:-}" ]] && set_conf "$CONF" "$sec" "Comment" "${!var}"
        mkdir -p "$incoming"
        try_chown amule:amule "$incoming"
        # Same device as / means the path isn't a bind mount: it lives in the
        # container's own writable layer and is lost when it is recreated.
        if [[ "$(stat -c %d /)" == "$(stat -c %d "$incoming")" ]]; then
            log "WARN: $incoming is not a mounted volume; downloads sent there are lost"
            log "      when the container is recreated. Add a bind mount for it in docker-compose.yml."
        fi
        n=$((n + 1))
    done
    # Count is only touched when categories are defined via environment;
    # when lowered, leftover Cat#N sections become orphans but aMule
    # ignores them.
    if (( n > 1 )); then
        set_conf "$CONF" "General" "Count" "$((n - 1))"
    fi
}

# amuleapi.conf lives next to amule.conf in $CONFIG_DIR and is a different
# file with a different format: plain [Section] Key=value read by
# wxFileConfig, but the EC password goes in CLEARTEXT (amuleapi has no
# --password flag on purpose: a password in argv is visible to every user
# on the machine through ps). amuleapi refuses to load the file unless it
# is mode 0600, so every write here is followed by a chmod.
API_CONF="$CONFIG_DIR/amuleapi.conf"

set_api_conf() {
    set_conf "$API_CONF" "$1" "$2" "$3"
    chmod 600 "$API_CONF"
    try_chown amule:amule "$API_CONF"
}

seed_api_config() {
    log "Generating initial amuleapi.conf at $API_CONF"
    ( umask 077; cat > "$API_CONF" <<'EOF'
[Server]
BindAddress=127.0.0.1
Port=4713
AllowCORS=0
StaticRoot=
[EC]
Host=127.0.0.1
Port=4712
Password=
Encryption=1
EOF
    )
    try_chown amule:amule "$API_CONF"
}

setup_user() {
    groupmod -o -g "$PGID" amule
    usermod -o -u "$PUID" amule
    chown -R amule:amule /home/amule
}

case "$ROLE" in
    amuled)
        if [[ -z "${EXTERNALCONNECT__ECPASSWORD:-}" ]]; then
            log "ERROR: EXTERNALCONNECT__ECPASSWORD is required (amuled won't start without an EC password)."
            exit 1
        fi
        mkdir -p "$CONFIG_DIR" /incoming /temp
        [[ -f "$CONF" ]] || seed_config
        apply_env_overrides
        setup_user
        apply_categories
        try_chown -R amule:amule "$CONFIG_DIR"
        try_chown -R amule:amule /temp
        try_chown amule:amule /incoming
        check_writable "$CONFIG_DIR"
        check_writable /temp
        check_writable /incoming
        log "Starting amuled (config in $CONFIG_DIR)"
        exec gosu amule amuled --config-dir="$CONFIG_DIR"
        ;;
    amuleweb)
        if [[ -z "${EXTERNALCONNECT__ECPASSWORD:-}" || -z "${WEBSERVER__PASSWORD:-}" ]]; then
            log "ERROR: EXTERNALCONNECT__ECPASSWORD and WEBSERVER__PASSWORD are required for amuleweb."
            exit 1
        fi
        setup_user
        EC_HOST="${EC_HOST:-amuled}"
        EC_PORT="${EXTERNALCONNECT__ECPORT:-4712}"
        WEB_PORT="${WEBSERVER__PORT:-4711}"
        log "Waiting for amuled at $EC_HOST:$EC_PORT..."
        for _ in $(seq 1 60); do
            if amulecmd -h "$EC_HOST" -p "$EC_PORT" -P "$EXTERNALCONNECT__ECPASSWORD" -c status > /dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        log "Starting amuleweb on port $WEB_PORT"
        exec gosu amule amuleweb \
            --host="$EC_HOST" \
            --port="$EC_PORT" \
            --password="$EXTERNALCONNECT__ECPASSWORD" \
            --admin-pass="$WEBSERVER__PASSWORD" \
            --server-port="$WEB_PORT" \
            --template="${AMULEWEB_TEMPLATE:-default}"
        ;;
    amuleapi)
        # The REST API + the new web frontend (master only; 3.0.1 has no
        # amuleapi binary). Talks to amuled over EC like amuleweb does, but
        # listens on its own port and serves the SPA from amuleapi-static.
        if ! command -v amuleapi > /dev/null 2>&1; then
            log "ERROR: this image has no amuleapi binary."
            log "       It only exists in aMule master: set AMULE_VERSION=master in .env,"
            log "       bump AMULE_GIT_REFRESH and rebuild (docker compose build)."
            exit 1
        fi
        if [[ -z "${EXTERNALCONNECT__ECPASSWORD:-}" || -z "${AMULEAPI_ADMIN_PASSWORD:-}" ]]; then
            log "ERROR: EXTERNALCONNECT__ECPASSWORD and AMULEAPI_ADMIN_PASSWORD are required for amuleapi."
            log "       The admin password is not optional here: amuleapi refuses to bind"
            log "       anything other than 127.0.0.1 until one is set, and in a container"
            log "       it has to bind 0.0.0.0 to be reachable at all."
            exit 1
        fi
        setup_user
        mkdir -p "$CONFIG_DIR"
        try_chown amule:amule "$CONFIG_DIR"
        check_writable "$CONFIG_DIR"
        EC_HOST="${EC_HOST:-amuled}"
        EC_PORT="${EXTERNALCONNECT__ECPORT:-4712}"
        API_PORT="${AMULEAPI_PORT:-4713}"
        # wxFileConfig expands $VAR in values unless the reader turns it off,
        # and amuleapi's reader doesn't — a dollar sign in the EC password
        # would come back as something else and the login would fail.
        if [[ "$EXTERNALCONNECT__ECPASSWORD" == *'$'* ]]; then
            log "WARN: the EC password contains '\$'; amuleapi reads amuleapi.conf with"
            log "      wxFileConfig, which expands \$VAR in values. Use a password without"
            log "      dollar signs if amuleapi can't log in to amuled."
        fi
        [[ -f "$API_CONF" ]] || seed_api_config
        set_api_conf EC Host "$EC_HOST"
        set_api_conf EC Port "$EC_PORT"
        set_api_conf EC Password "$EXTERNALCONNECT__ECPASSWORD"
        set_api_conf Server Port "$API_PORT"
        # --bind on the command line already forces this, but a conf still
        # reading 127.0.0.1 while the daemon listens on 0.0.0.0 is a trap for
        # whoever debugs this next.
        set_api_conf Server BindAddress "0.0.0.0"
        # 0600 means owner-only, so a chown that failed above (network
        # filesystem) leaves a root-owned file that amuleapi, running as
        # amule, cannot read — and its own error doesn't say why.
        if ! gosu amule test -r "$API_CONF"; then
            log "ERROR: $API_CONF is not readable by uid $PUID:$PGID."
            log "       amuleapi requires mode 0600 on it, so it must be owned by that uid."
            log "       Fix the ownership of $CONFIG_DIR on the host, or put it on a"
            log "       filesystem where chown works (not NFS with root_squash)."
            exit 1
        fi
        # Passwords are stored salted+stretched in amuleapi-passwords; these
        # commands only write the file and exit, so they are safe to repeat on
        # every start. An empty guest password is what turns guest access off.
        log "Setting the amuleapi admin password"
        gosu amule amuleapi --config-dir="$CONFIG_DIR" --set-admin-pass="$AMULEAPI_ADMIN_PASSWORD"
        if [[ -n "${AMULEAPI_GUEST_PASSWORD:-}" ]]; then
            log "Setting the amuleapi guest password (read-only access)"
            gosu amule amuleapi --config-dir="$CONFIG_DIR" --set-guest-pass="$AMULEAPI_GUEST_PASSWORD"
        fi
        log "Waiting for amuled at $EC_HOST:$EC_PORT..."
        for _ in $(seq 1 60); do
            if amulecmd -h "$EC_HOST" -p "$EC_PORT" -P "$EXTERNALCONNECT__ECPASSWORD" -c status > /dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        log "Starting amuleapi on port $API_PORT"
        exec gosu amule amuleapi \
            --config-dir="$CONFIG_DIR" \
            --host="$EC_HOST" \
            --port="$EC_PORT" \
            --bind=0.0.0.0 \
            --http-port="$API_PORT"
        ;;
    *)
        exec "$@"
        ;;
esac
