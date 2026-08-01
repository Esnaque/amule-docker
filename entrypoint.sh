#!/bin/bash
# Entrypoint for amuled and amuleweb.
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
    *)
        exec "$@"
        ;;
esac
