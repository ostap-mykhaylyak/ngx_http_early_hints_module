# Guida completa — modulo nginx Early Hints

Dalla pubblicazione su GitHub fino al deploy in produzione, passo per passo.

Indice:
1. [Cosa contiene il progetto](#1-cosa-contiene-il-progetto)
2. [Prerequisiti](#2-prerequisiti)
3. [Pubblicare il repo su GitHub](#3-pubblicare-il-repo-su-github)
4. [Build + test in locale](#4-build--test-in-locale)
5. [CI su GitHub Actions](#5-ci-su-github-actions)
6. [Deploy sul server](#6-deploy-sul-server)
7. [Configurazione nginx](#7-configurazione-nginx)
8. [Verifica in produzione](#8-verifica-in-produzione)
9. [Risoluzione problemi](#9-risoluzione-problemi)

---

## 1. Cosa contiene il progetto

```
ngx_http_early_hints_module/
├── config                          # script di build del modulo (per nginx)
├── ngx_http_early_hints_module.c   # sorgente del modulo
├── build.sh                        # scarica nginx, compila, testa, installa
├── example.conf                    # esempi di configurazione nginx
├── README.md                       # documentazione del modulo
├── GUIDA.md                        # questa guida
├── .gitattributes                  # forza line endings LF
└── .github/workflows/build.yml     # CI: build + test ad ogni push
```

**Cosa fa il modulo:** consente a nginx (il web server) di emettere una
risposta **103 Early Hints** con header `Link` definiti in configurazione,
funzionando su **HTTP/1.1, HTTP/2 e HTTP/3**. Si appoggia alla funzione del
core `ngx_http_send_early_hints()` (nginx ≥ 1.29.0).

---

## 2. Prerequisiti

**Per compilare (server Linux o WSL):**
- `gcc`, `make`, `git`, `curl`
- header di sviluppo di **PCRE2**, **zlib**, **OpenSSL** (≥ 3.0 per HTTP/3)
- nginx **≥ 1.29.1** come versione target (default dello script: `1.31.1`)

> Lo `build.sh` installa da solo queste dipendenze su Debian/Ubuntu,
> RHEL/Fedora/Alma/Rocky e Alpine.

**Per pubblicare:** un account GitHub e `git` configurato.

> **Windows:** nginx si compila su Linux. Da Windows usa **WSL2**
> (`wsl --install`, poi una shell Ubuntu) oppure un server/container Linux.
> Il push su GitHub puoi farlo anche da Windows.

---

## 3. Pubblicare il repo su GitHub

Dalla cartella del progetto:

```bash
git init
git add .
git commit -m "modulo nginx early_hints: build, test, CI"
git branch -M main
git remote add origin https://github.com/TUO-UTENTE/TUO-REPO.git
git push -u origin main
```

> Il file `.gitattributes` garantisce che gli script restino in formato LF
> anche committando da Windows. **Non saltarlo**: senza, su Linux otterresti
> l'errore `bad interpreter: /usr/bin/env bash^M`.

---

## 4. Build + test in locale

Su una macchina Linux (o WSL2), dentro la checkout del repo:

```bash
chmod +x build.sh

# build dinamica (default) + test, senza installare:
./build.sh --no-install
```

Lo script:
1. installa le dipendenze,
2. scarica `nginx-1.31.1`,
3. compila il modulo,
4. **esegue i test** (deve stampare `Tutti i test superati`),
5. (senza `--no-install`) installa in `/usr/local/nginx`.

Varianti utili:

```bash
# installa davvero (richiede root/sudo)
sudo ./build.sh

# modulo statico (dentro il binario nginx)
LINK_MODE=static ./build.sh

# versione nginx diversa, prefisso custom
NGINX_VERSION=1.31.1 PREFIX=/opt/nginx ./build.sh

# se HTTP/3 dà problemi a compilare, disabilitalo
WITH_HTTP3=0 ./build.sh

# solo i test su un build già fatto
./build.sh --test-only
```

Se compili il modulo **da un altro repo** (non dalla checkout corrente):

```bash
MODULE_REPO=https://github.com/TUO-UTENTE/TUO-REPO.git \
MODULE_REF=main \
./build.sh
```

---

## 5. CI su GitHub Actions

Il workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) parte
**ad ogni push** su `main`/`master`, ad ogni pull request e su avvio manuale
(tab **Actions → build-and-test → Run workflow**).

Per ogni combinazione (`dynamic`/`static`) esegue `./build.sh --no-install`,
quindi build + test funzionali. In caso di fallimento carica i log come
artifact; per la build dinamica carica anche il `.so` compilato (scaricabile
dalla pagina del run, sezione **Artifacts**).

Non serve alcun segreto né configurazione: il workflow usa la checkout del
repo come sorgente del modulo.

---

## 6. Deploy sul server

### Opzione A — modulo dinamico (consigliata)

Compila **sul server** (o su una macchina con stessa distro/versione) con
install completo:

```bash
git clone https://github.com/TUO-UTENTE/TUO-REPO.git
cd TUO-REPO
sudo ./build.sh
```

Questo installa nginx + il `.so` in `/usr/local/nginx/`. Il binario è
compilato `--with-compat`, quindi il `.so` è caricabile con `load_module`.

> **Vuoi usare un nginx già installato dalla distro** (es. pacchetto
> `nginx`)? Allora il `.so` va compilato contro **la stessa identica versione
> e con flag compatibili** (`--with-compat`). Verifica la versione con
> `nginx -v` e i flag con `nginx -V`, imposta `NGINX_VERSION` di conseguenza,
> compila con `--no-install` e copia a mano `objs/ngx_http_early_hints_set_module.so`
> nella cartella moduli della distro (di solito `/etc/nginx/modules/`).

### Opzione B — modulo statico

`LINK_MODE=static sudo ./build.sh` produce un binario nginx con il modulo
già dentro: nessun `load_module` necessario, ma per aggiornare nginx dovrai
ricompilare.

---

## 7. Configurazione nginx

Nel `nginx.conf`, **a livello main** (solo per build dinamica):

```nginx
load_module modules/ngx_http_early_hints_set_module.so;
```

Dentro un `server`/`location` servono **due** direttive:

```nginx
location / {
    early_hints      1;                                    # GATE (core): ON
    early_hints_link "</css/style.css>; rel=preload; as=style";
    early_hints_link "</js/app.js>;     rel=preload; as=script";

    proxy_pass http://backend;     # oppure root + try_files
}
```

- `early_hints_link` (questo modulo) = **cosa** inviare (ripetibile, accetta
  variabili nginx).
- `early_hints` (core nginx) = **se** inviare. Metti `1` per "sempre", oppure
  una variabile per condizionare (es. solo HTTP/2/3, solo navigazioni).

Esempi completi (per protocollo, condizionati, per path) in
[`example.conf`](example.conf).

Applica:

```bash
sudo /usr/local/nginx/sbin/nginx -t      # test config
sudo /usr/local/nginx/sbin/nginx -s reload
```

---

## 8. Verifica in produzione

```bash
# HTTP/2
curl -sv --http2 https://tuo-host/ 2>&1 | grep -iE '103|link:'

# HTTP/1.1
curl -sv --http1.1 https://tuo-host/ 2>&1 | grep -iE '103|Link:'

# HTTP/3 (curl con supporto h3)
curl -sv --http3 https://tuo-host/ 2>&1 | grep -iE '103|link:'
```

Atteso: una riga di status **`103`** con gli header **`Link`** *prima* del
`200 OK`. Nei DevTools del browser (tab Network) vedrai le risorse precaricate
partire prima della risposta principale.

---

## 9. Risoluzione problemi

| Sintomo | Causa / soluzione |
|---------|-------------------|
| `bad interpreter: bash^M` | File in CRLF. Assicurati che `.gitattributes` ci sia e ri-clona, oppure `sed -i 's/\r$//' build.sh`. |
| `./configure` fallisce su QUIC/HTTP/3 | OpenSSL troppo vecchio. Rilancia con `WITH_HTTP3=0`, oppure aggiorna OpenSSL ≥ 3.0. |
| Nessun `103` nella risposta | Manca il gate: aggiungi `early_hints 1;` accanto a `early_hints_link`. |
| `103` su HTTP/1.1 sì, su HTTP/2 no | Versione nginx < 1.29.1 (bug di buffering h2). Usa ≥ 1.29.1. |
| `module ... is not binary compatible` | Il `.so` è stato compilato contro una versione/flag diversi dal nginx in uso. Ricompila con la stessa `NGINX_VERSION` e `--with-compat`. |
| `unknown directive "early_hints_link"` | Il modulo non è caricato: manca `load_module` (build dinamica) o il binario non lo include (build statica). Controlla con `nginx -V`. |
| `unknown directive "early_hints"` | nginx < 1.29.0: la direttiva nativa di gate non esiste. Aggiorna nginx. |
| Test h2/h3 in `SKIP` | `openssl` assente o `curl` senza supporto h2/h3. Non è un errore del modulo. |

Per il debug dei test locali, i log stanno in `.build/test/logs/error.log`.
