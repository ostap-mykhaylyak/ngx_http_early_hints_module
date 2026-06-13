#!/usr/bin/env bash
#
# build.sh — scarica nginx + il modulo early_hints, compila e configura.
#
# Compila nginx DA SORGENTE includendo il modulo (dinamico per default), così
# binario e modulo combaciano per versione/flag. Funziona su Debian/Ubuntu,
# RHEL/Fedora/Alma/Rocky e Alpine (rileva il package manager).
#
# Uso:
#   ./build.sh                      # build dinamica, install in /usr/local/nginx
#   NGINX_VERSION=1.31.1 ./build.sh
#   MODULE_REPO=https://github.com/UTENTE/REPO.git ./build.sh
#   LINK_MODE=static ./build.sh     # modulo compilato dentro il binario
#   ./build.sh --no-install         # compila ma non installa
#
# Variabili d'ambiente principali (tutte con default):
#   NGINX_VERSION   versione nginx da scaricare, oppure    (default: 1.31.1)
#                   "latest" per l'ultima da nginx.org
#   MODULE_REPO     URL git del repo del modulo            (OBBLIGATORIA*)
#   MODULE_REF      branch/tag/commit del modulo           (default: main)
#   LINK_MODE       dynamic | static                       (default: dynamic)
#   PREFIX          prefisso d'installazione nginx         (default: /usr/local/nginx)
#   BUILD_DIR       cartella di lavoro                     (default: ./.build)
#   JOBS            parallelismo make                      (default: nproc)
#   WITH_HTTP3      1 per includere HTTP/3 (QUIC)          (default: 1)
#   TEST_CURL       curl da usare nei test (es. uno con    (default: curl)
#                   supporto HTTP/3)
#
#   * Se lo lanci DENTRO una checkout del repo del modulo (c'è ./config),
#     MODULE_REPO è opzionale: usa la cartella corrente.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Config / default
# ----------------------------------------------------------------------------
NGINX_VERSION="${NGINX_VERSION:-1.31.1}"
MODULE_REPO="${MODULE_REPO:-}"
MODULE_REF="${MODULE_REF:-main}"
LINK_MODE="${LINK_MODE:-dynamic}"
PREFIX="${PREFIX:-/usr/local/nginx}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/.build}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
WITH_HTTP3="${WITH_HTTP3:-1}"
# curl usato per i test funzionali (puo' essere un curl con supporto HTTP/3,
# diverso da quello di sistema). Default: il curl nel PATH.
TEST_CURL="${TEST_CURL:-curl}"

DO_INSTALL=1
DO_TEST=1
TEST_ONLY=0
TEST_PORT_H1="${TEST_PORT_H1:-8099}"
TEST_PORT_TLS="${TEST_PORT_TLS:-8443}"
for arg in "$@"; do
    case "$arg" in
        --no-install) DO_INSTALL=0 ;;
        --no-test)    DO_TEST=0 ;;
        --test-only)  TEST_ONLY=1 ;;
        --static)     LINK_MODE=static ;;
        --dynamic)    LINK_MODE=dynamic ;;
        -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "Argomento sconosciuto: $arg" >&2; exit 2 ;;
    esac
done

MODULE_DIR="${BUILD_DIR}/module"
SO_NAME="ngx_http_early_hints_set_module.so"

# Variabili derivate dalla versione (ricalcolate dopo l'eventuale "latest").
set_paths() {
    NGINX_TARBALL="nginx-${NGINX_VERSION}.tar.gz"
    NGINX_URL="https://nginx.org/download/${NGINX_TARBALL}"
    NGINX_SRC="${BUILD_DIR}/nginx-${NGINX_VERSION}"
}
set_paths

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
if [ -t 1 ]; then C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else C_B=; C_G=; C_Y=; C_R=; C_0=; fi
log()  { echo "${C_G}${C_B}==>${C_0}${C_B} $*${C_0}"; }
warn() { echo "${C_Y}${C_B}!! ${C_0} $*${C_0}" >&2; }
die()  { echo "${C_R}${C_B}xx ${C_0} $*${C_0}" >&2; exit 1; }

SUDO=""
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 && SUDO="sudo" \
            || die "Servono privilegi di root per '$1' (installa sudo o esegui come root)."
    fi
}

# ----------------------------------------------------------------------------
# 1. Dipendenze di build
# ----------------------------------------------------------------------------
install_deps() {
    log "Installazione dipendenze di build"
    if   command -v apt-get >/dev/null 2>&1; then
        need_root apt-get
        $SUDO apt-get update -y
        $SUDO apt-get install -y --no-install-recommends \
            build-essential ca-certificates curl git \
            libpcre2-dev zlib1g-dev libssl-dev
    elif command -v dnf >/dev/null 2>&1; then
        need_root dnf
        $SUDO dnf install -y \
            gcc make ca-certificates curl git \
            pcre2-devel zlib-devel openssl-devel
    elif command -v yum >/dev/null 2>&1; then
        need_root yum
        $SUDO yum install -y \
            gcc make ca-certificates curl git \
            pcre2-devel zlib-devel openssl-devel
    elif command -v apk >/dev/null 2>&1; then
        need_root apk
        $SUDO apk add --no-cache \
            build-base ca-certificates curl git \
            pcre2-dev zlib-dev openssl-dev linux-headers
    else
        warn "Package manager non riconosciuto: assicurati di avere gcc, make,"
        warn "git, curl e gli header di PCRE2, zlib, OpenSSL."
    fi
}

# ----------------------------------------------------------------------------
# 1b. Risoluzione versione (NGINX_VERSION=latest -> ultima release nginx.org)
# ----------------------------------------------------------------------------
resolve_nginx_version() {
    if [ "$NGINX_VERSION" != "latest" ]; then
        return 0
    fi
    log "Rilevo l'ultima versione di nginx da nginx.org"
    NGINX_VERSION="$(
        curl -fsSL https://nginx.org/download/ \
        | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^nginx-([0-9.]+)\.tar\.gz$/\1/' \
        | sort -V | tail -n1
    )"
    [ -n "$NGINX_VERSION" ] || die "Impossibile rilevare l'ultima versione di nginx."
    log "Ultima versione nginx: ${NGINX_VERSION}"
    set_paths
}

# ----------------------------------------------------------------------------
# 2. Sorgente nginx
# ----------------------------------------------------------------------------
fetch_nginx() {
    mkdir -p "$BUILD_DIR"
    if [ -d "$NGINX_SRC" ]; then
        log "Sorgente nginx già presente: $NGINX_SRC"
        return
    fi
    log "Download nginx ${NGINX_VERSION}"
    curl -fSL --retry 3 -o "${BUILD_DIR}/${NGINX_TARBALL}" "$NGINX_URL" \
        || die "Download nginx fallito ($NGINX_URL). Versione inesistente?"
    log "Estrazione"
    tar -xzf "${BUILD_DIR}/${NGINX_TARBALL}" -C "$BUILD_DIR"
    [ -d "$NGINX_SRC" ] || die "Cartella sorgente attesa non trovata: $NGINX_SRC"
}

# ----------------------------------------------------------------------------
# 3. Sorgente del modulo
# ----------------------------------------------------------------------------
fetch_module() {
    # Caso A: lanciato dentro la checkout del modulo (c'è ./config + .c)
    if [ -z "$MODULE_REPO" ] && [ -f "./config" ] \
       && ls ./*.c >/dev/null 2>&1; then
        log "Uso il modulo dalla cartella corrente: $(pwd)"
        MODULE_DIR="$(pwd)"
        return
    fi
    [ -n "$MODULE_REPO" ] || die "MODULE_REPO non impostata e non sono in una checkout del modulo.
Esempio: MODULE_REPO=https://github.com/UTENTE/REPO.git ./build.sh"

    if [ -d "$MODULE_DIR/.git" ]; then
        log "Aggiorno il modulo ($MODULE_DIR)"
        git -C "$MODULE_DIR" fetch --depth 1 origin "$MODULE_REF"
        git -C "$MODULE_DIR" checkout -q FETCH_HEAD
    else
        log "Clono il modulo da $MODULE_REPO ($MODULE_REF)"
        rm -rf "$MODULE_DIR"
        git clone --depth 1 --branch "$MODULE_REF" "$MODULE_REPO" "$MODULE_DIR" 2>/dev/null \
            || { # il ref potrebbe essere un commit: clona e checkout
                 git clone "$MODULE_REPO" "$MODULE_DIR"
                 git -C "$MODULE_DIR" checkout -q "$MODULE_REF"; }
    fi

    # se il repo ha il modulo in una sottocartella, individuala
    if [ ! -f "$MODULE_DIR/config" ]; then
        local found
        found="$(grep -rl --include=config 'ngx_addon_name' "$MODULE_DIR" 2>/dev/null | head -n1 || true)"
        [ -n "$found" ] || die "Nel repo non trovo un file 'config' di modulo nginx."
        MODULE_DIR="$(dirname "$found")"
        log "Modulo trovato in: $MODULE_DIR"
    fi
}

# ----------------------------------------------------------------------------
# 4. Configure + compile
# ----------------------------------------------------------------------------
build_nginx() {
    log "Configurazione build nginx (LINK_MODE=$LINK_MODE, HTTP/3=$WITH_HTTP3)"

    local addmod="--add-dynamic-module=${MODULE_DIR}"
    [ "$LINK_MODE" = "static" ] && addmod="--add-module=${MODULE_DIR}"

    local http3_opts=()
    if [ "$WITH_HTTP3" = "1" ]; then
        http3_opts=( --with-http_v3_module )
    fi

    cd "$NGINX_SRC"
    ./configure \
        --prefix="${PREFIX}" \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        "${http3_opts[@]}" \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        ${addmod} \
        || die "./configure fallito. Se l'errore riguarda HTTP/3, rilancia con WITH_HTTP3=0."

    log "Compilazione (make -j${JOBS})"
    if [ "$LINK_MODE" = "static" ]; then
        make -j"${JOBS}"
    else
        make -j"${JOBS}" modules
        make -j"${JOBS}"          # binario nginx --with-compat
    fi
    log "Compilazione completata"
}

# ----------------------------------------------------------------------------
# 5. Install
# ----------------------------------------------------------------------------
install_nginx() {
    [ "$DO_INSTALL" = "1" ] || { warn "--no-install: salto l'installazione"; return; }
    need_root "make install"
    log "Installazione in ${PREFIX}"
    cd "$NGINX_SRC"
    $SUDO make install

    if [ "$LINK_MODE" = "dynamic" ]; then
        $SUDO mkdir -p "${PREFIX}/modules"
        $SUDO cp -v "objs/${SO_NAME}" "${PREFIX}/modules/${SO_NAME}"
    fi
}

# ----------------------------------------------------------------------------
# 6. Config d'esempio + verifica
# ----------------------------------------------------------------------------
write_sample_conf() {
    local snippet="${BUILD_DIR}/early_hints.sample.conf"
    local load_line=""
    [ "$LINK_MODE" = "dynamic" ] && load_line="load_module modules/${SO_NAME};"

    cat > "$snippet" <<EOF
# Snippet generato da build.sh — integra nel tuo nginx.conf.
${load_line}

# ... dentro http { server { ... } }:
#
#   location / {
#       early_hints      1;                                    # gate del core (ON)
#       early_hints_link "</css/style.css>; rel=preload; as=style";
#       early_hints_link "</js/app.js>;     rel=preload; as=script";
#       proxy_pass http://backend;
#   }
EOF
    log "Snippet di esempio scritto in: ${snippet}"
    if [ -n "$load_line" ]; then
        warn "Ricorda: aggiungi a inizio nginx.conf -> ${load_line}"
    fi
    return 0
}

verify() {
    local bin="${PREFIX}/sbin/nginx"
    [ -x "$bin" ] || bin="$(test_bin)"
    [ -x "$bin" ] || bin="$(command -v nginx || true)"
    [ -n "$bin" ] && [ -x "$bin" ] || { warn "Binario nginx non trovato per la verifica"; return 0; }

    log "Versione e flag di build:"
    "$bin" -V 2>&1 | sed 's/^/    /'

    if "$bin" -V 2>&1 | grep -q 'early_hints_set_module'; then
        log "${C_G}OK: il modulo risulta nei flag di configure.${C_0}"
    elif [ "$LINK_MODE" = "dynamic" ]; then
        log "Modulo dinamico: caricalo con 'load_module modules/${SO_NAME};'"
    fi
}

# ----------------------------------------------------------------------------
# 7. Test funzionale: avvia nginx e verifica che arrivi il 103 + Link
# ----------------------------------------------------------------------------
test_bin() {
    # binario da testare: preferisci quello appena compilato in objs/
    if [ -x "${NGINX_SRC}/objs/nginx" ]; then
        echo "${NGINX_SRC}/objs/nginx"
    elif [ -x "${PREFIX}/sbin/nginx" ]; then
        echo "${PREFIX}/sbin/nginx"
    else
        echo ""
    fi
}

run_test() {
    [ "$DO_TEST" = "1" ] || { warn "--no-test: salto il test"; return; }

    local bin; bin="$(test_bin)"
    [ -n "$bin" ] || die "Test: binario nginx non trovato (compila prima)."
    command -v "$TEST_CURL" >/dev/null 2>&1 || die "Test: 'curl' non trovato ($TEST_CURL)."

    log "Test funzionale del modulo early_hints (curl: $("$TEST_CURL" --version | head -n1))"

    local T="${BUILD_DIR}/test"
    rm -rf "$T"; mkdir -p "$T/logs" "$T/html" "$T/conf"
    echo "<h1>ok</h1>" > "$T/html/index.html"

    # riga load_module solo per build dinamica
    local load_line=""
    if [ "$LINK_MODE" = "dynamic" ]; then
        load_line="load_module \"${NGINX_SRC}/objs/${SO_NAME}\";"
    fi

    # certificato self-signed per i test TLS (h2/h3)
    local have_tls=0
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
            -keyout "$T/conf/key.pem" -out "$T/conf/cert.pem" \
            -subj "/CN=localhost" >/dev/null 2>&1 && have_tls=1
    fi
    [ "$have_tls" = "1" ] || warn "openssl assente: salto i test h2/h3 (solo HTTP/1.1)."

    # blocchi listen TLS opzionali
    local tls_server=""
    if [ "$have_tls" = "1" ]; then
        local h3_listen=""
        [ "$WITH_HTTP3" = "1" ] && h3_listen="
        listen 127.0.0.1:${TEST_PORT_TLS} quic reuseport;
        http3 on;
        add_header Alt-Svc 'h3=\":${TEST_PORT_TLS}\"; ma=86400';"
        tls_server="
    server {
        listen 127.0.0.1:${TEST_PORT_TLS} ssl;
        http2 on;${h3_listen}
        ssl_certificate     \"${T}/conf/cert.pem\";
        ssl_certificate_key \"${T}/conf/key.pem\";
        root \"${T}/html\";
        location / {
            early_hints      1;
            early_hints_link \"</css/style.css>; rel=preload; as=style\";
            early_hints_link \"</js/app.js>; rel=preload; as=script\";
        }
    }"
    fi

    cat > "$T/conf/nginx.conf" <<EOF
${load_line}
daemon on;
pid "${T}/nginx.pid";
error_log "${T}/logs/error.log" info;
events { worker_connections 64; }
http {
    access_log off;
    server {
        listen 127.0.0.1:${TEST_PORT_H1};
        root "${T}/html";
        location / {
            early_hints      1;
            early_hints_link "</css/style.css>; rel=preload; as=style";
            early_hints_link "</js/app.js>; rel=preload; as=script";
        }
    }${tls_server}
}
EOF

    # avvio nginx di test
    "$bin" -p "$T" -c "$T/conf/nginx.conf" -t \
        || { cat "$T/logs/error.log" 2>/dev/null; die "Test: config non valida."; }
    "$bin" -p "$T" -c "$T/conf/nginx.conf"
    # attendi che la porta risponda
    local i; for i in $(seq 1 20); do
        "$TEST_CURL" -s -o /dev/null "http://127.0.0.1:${TEST_PORT_H1}/" && break || sleep 0.2
    done

    local fails=0

    _check() { # $1=descrizione  $2=output curl
        if echo "$2" | grep -qiE '< *HTTP/[0-9.]+ 103' \
           && echo "$2" | grep -qi 'preload'; then
            log "  ${C_G}PASS${C_0} — $1 (103 + Link ricevuti)"
        else
            warn "  ${C_R}FAIL${C_0} — $1 (nessun 103/Link)"
            echo "$2" | grep -iE '^< ' | sed 's/^/        /'
            fails=$((fails+1))
        fi
    }

    # --- HTTP/1.1 (sempre) ---
    local out
    out="$("$TEST_CURL" -sv --http1.1 "http://127.0.0.1:${TEST_PORT_H1}/" 2>&1 || true)"
    _check "HTTP/1.1" "$out"

    # --- HTTP/2 (se TLS) ---
    if [ "$have_tls" = "1" ] && "$TEST_CURL" --version | grep -qi 'HTTP2'; then
        out="$("$TEST_CURL" -ksv --http2 "https://127.0.0.1:${TEST_PORT_TLS}/" 2>&1 || true)"
        _check "HTTP/2"  "$out"
    else
        warn "  SKIP — HTTP/2 (TLS o supporto curl assente)"
    fi

    # --- HTTP/3 ---
    if [ "$have_tls" = "1" ] && [ "$WITH_HTTP3" = "1" ] \
       && "$TEST_CURL" --version | grep -qi 'HTTP3'; then
        out="$("$TEST_CURL" -ksv --http3-only "https://127.0.0.1:${TEST_PORT_TLS}/" 2>&1 \
               || "$TEST_CURL" -ksv --http3 "https://127.0.0.1:${TEST_PORT_TLS}/" 2>&1 || true)"
        _check "HTTP/3"  "$out"
    else
        warn "  SKIP — HTTP/3 (curl senza supporto h3 o WITH_HTTP3=0)"
    fi

    # stop nginx di test
    "$bin" -p "$T" -c "$T/conf/nginx.conf" -s stop >/dev/null 2>&1 || true

    if [ "$fails" -gt 0 ]; then
        die "Test FALLITO: $fails controllo/i non superato/i. Log: ${T}/logs/error.log"
    fi
    log "${C_G}${C_B}Tutti i test superati.${C_0}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    if [ "$TEST_ONLY" = "1" ]; then
        log "Solo test (--test-only) sul build esistente"
        [ -n "$(test_bin)" ] || die "Nessun binario compilato in ${NGINX_SRC}/objs o ${PREFIX}/sbin."
        run_test
        exit 0
    fi

    resolve_nginx_version
    log "nginx ${NGINX_VERSION} | modulo: ${MODULE_REPO:-<cartella corrente>} (${MODULE_REF}) | $LINK_MODE"
    install_deps
    fetch_nginx
    fetch_module
    build_nginx
    run_test
    install_nginx
    write_sample_conf
    verify
    log "${C_G}${C_B}Fatto.${C_0}"
    if [ "$DO_INSTALL" = "1" ]; then
        echo
        echo "Prossimi passi:"
        echo "  1) integra lo snippet ${BUILD_DIR}/early_hints.sample.conf nel tuo nginx.conf"
        echo "  2) ${PREFIX}/sbin/nginx -t       # test config"
        echo "  3) ${PREFIX}/sbin/nginx          # avvio   (o -s reload se già attivo)"
    fi
}

main "$@"
