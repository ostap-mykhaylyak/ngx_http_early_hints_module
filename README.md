# ngx_http_early_hints_set_module

Modulo nativo nginx che permette al **web server** di generare gli header
`Link` di una risposta **103 Early Hints** direttamente dalla configurazione,
senza che sia il backend a emetterli.

Funziona su **HTTP/1.1, HTTP/2 e HTTP/3**: lo smistamento per protocollo
(raw / HPACK / QPACK) è gestito dal core di nginx, non da questo modulo.

- Richiede **nginx ≥ 1.29.0** (introduzione di `ngx_http_send_early_hints()`
  e della direttiva nativa `early_hints`).
- Usa solo API pubbliche → compilabile con `--with-compat` (caricabile come
  modulo dinamico senza ricompilare tutto nginx, a parità di flag).

---

## Perché non basta la direttiva nativa `early_hints`

La direttiva nativa del core è un **passthrough condizionale**: inoltra al
client il 103 *ricevuto da un upstream*. Non genera nulla da sola.

> *"103 (Early Hints) responses received from an upstream server are passed to
> a client as is, without interpretation."*

Questo modulo copre il caso opposto: **è nginx a comporre i `Link`**, utile
quando non puoi/non vuoi modificare il backend, o quando nginx serve contenuto
statico.

---

## Come funziona

1. La direttiva `early_hints_link` (fornita da questo modulo) definisce i
   valori `Link` da inviare.
2. Nella fase `PRECONTENT` il modulo inserisce quei `Link` in
   `r->headers_out.headers` e chiama `ngx_http_send_early_hints()`.
3. Il core emette il **103** scegliendo la codifica giusta per il protocollo
   della connessione.
4. Dopo l'invio il modulo azzera l'`hash` delle voci aggiunte, così **non**
   vengono ripetute negli header della risposta finale (`200`, ...).

### Ruoli separati: cosa vs se

| Direttiva | Chi la fornisce | Ruolo |
|-----------|-----------------|-------|
| `early_hints_link` | questo modulo | **COSA** inviare (i `Link`) |
| `early_hints`      | core nginx     | **SE** inviare (gate/condizione) |

`ngx_http_send_early_hints()` invia **solo se** la direttiva nativa
`early_hints` valuta come "vero" (almeno un valore non vuoto e diverso da
`"0"`). Quindi **servono entrambe** le direttive.

---

## Direttive

### `early_hints_link`

```
Sintassi:  early_hints_link string;
Default:   —
Contesto:  http, server, location, if-in-location
```

Aggiunge un header `Link` alla risposta 103. **Ripetibile** (una per riga).
Il valore è un *complex value*: può contenere variabili nginx.

```nginx
early_hints_link "</css/style.css>; rel=preload; as=style";
early_hints_link "<$scheme://$host/app.js>; rel=preload; as=script";
early_hints_link "<https://cdn.example.com>; rel=preconnect";
```

Ereditarietà: se una `location` definisce un proprio `early_hints_link`, **non**
eredita quelli del livello superiore (comportamento "array", come la maggior
parte delle direttive di tipo lista in nginx).

### `early_hints` (nativa del core — gate)

```
Sintassi:  early_hints string ...;
Contesto:  http, server, location
```

Abilita l'invio se almeno un valore è non vuoto e diverso da `"0"`. Usa `1`
per "sempre on", oppure una variabile per condizionare.

---

## Build

Modulo dinamico (consigliato):

```sh
cd /path/a/nginx-1.31.1          # STESSA versione del binario in uso
./configure --with-compat \
            --with-http_v2_module \
            --with-http_v3_module \
            --add-dynamic-module=/path/a/ngx_http_early_hints_module
make modules
sudo cp objs/ngx_http_early_hints_set_module.so /etc/nginx/modules/
sudo nginx -t && sudo nginx -s reload
```

Statico (compilato dentro il binario): sostituire
`--add-dynamic-module` con `--add-module` e ricompilare nginx
(`make && make install`); in questo caso **non** serve `load_module`.

---

## Uso

Vedi [`example.conf`](example.conf) per esempi completi. Minimo:

```nginx
load_module modules/ngx_http_early_hints_set_module.so;

http {
    server {
        listen 443 ssl;
        listen 443 quic reuseport;
        http2 on;
        http3 on;

        location / {
            early_hints      1;                                    # gate ON
            early_hints_link "</css/style.css>; rel=preload; as=style";
            early_hints_link "</js/app.js>;     rel=preload; as=script";

            proxy_pass http://backend;     # oppure root + try_files: indifferente
        }
    }
}
```

---

## Verifica

```sh
# HTTP/2
curl -sv --http2 https://tuo-host/ 2>&1 | grep -iE '^< (HTTP/2 103|link:)'

# HTTP/3 (curl buildato con HTTP/3)
curl -sv --http3 https://tuo-host/ 2>&1 | grep -iE '^< (HTTP/3 103|link:)'

# HTTP/1.1
curl -sv --http1.1 https://tuo-host/ 2>&1 | grep -iE '^< (HTTP/1.1 103|Link:)'
```

Atteso: uno status `103` con gli header `Link` **prima** del `200`.

---

## Note e limiti

- **Serve il gate.** Senza `early_hints` (nativa) valutata vera, non viene
  inviato nulla: è voluto, così puoi spegnerlo/condizionarlo da config.
- **HTTP/1.0**: nessun 103 (lo standard richiede ≥ 1.1). Il modulo salta.
- **Una sola emissione** per richiesta (la spec ne consente più d'una, ma qui
  inviamo un singolo 103 con tutti i `Link` configurati).
- **Solo richiesta principale**, non le subrequest (`SSI`, `auth_request`, ...).
- **Buffering HTTP/2**: corretto da nginx 1.29.1; assicurati di essere ≥ 1.29.1
  (tu sei su 1.31.1 → ok).
- **Proxy intermedi vecchi** su HTTP/1.1 potrebbero non gradire i 1xx: in pratica
  con TLS + h2/h3 (caso d'uso reale degli early hints) non è un problema.
- Gli header `Link` di preload **non** vengono ripetuti nel `200` (azzeriamo
  l'hash). Se invece li vuoi anche nella risposta finale, aggiungili a parte
  con `add_header Link "...";`.
