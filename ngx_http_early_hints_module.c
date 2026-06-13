/*
 * ngx_http_early_hints_set_module
 *
 * Permette al web server (nginx) di GENERARE gli header "Link" di una
 * risposta informativa "103 Early Hints" direttamente dalla config, senza
 * che sia il backend a emetterli.
 *
 * Si appoggia alla macchina nativa del core (nginx >= 1.29.0):
 *   - ngx_http_send_early_hints()  -> invia headers_out.headers come 103
 *   - lo smistamento per protocollo (raw HTTP/1.1, HPACK HTTP/2, QPACK
 *     HTTP/3) e' gestito dal core via ngx_http_top_early_hints_filter.
 * Usa solo API pubbliche: compilabile con --with-compat.
 *
 * Direttive:
 *
 *   early_hints_link "</css/style.css>; rel=preload; as=style";   # ripetibile
 *   early_hints      $abilita;   # DIRETTIVA NATIVA: gate on/off (vedi nota)
 *
 * Il valore di early_hints_link e' un complex value: puo' usare variabili
 * nginx, es.  early_hints_link "<$scheme://$host/a.css>; rel=preload; as=style";
 *
 * NOTA SUL GATE
 * -------------
 * ngx_http_send_early_hints() invia solo se la direttiva NATIVA "early_hints"
 * (core) valuta come "passa" (almeno un valore non vuoto e diverso da "0").
 * Quindi per attivare l'invio servono ENTRAMBE:
 *
 *     early_hints      1;                       # gate del core: abilita
 *     early_hints_link "</a.css>; rel=preload"; # cosa inviare (questo modulo)
 *
 * Cosi' puoi anche condizionare l'invio (es. solo h2/h3, solo navigazioni)
 * sfruttando la direttiva nativa, senza toccare questo modulo.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


typedef struct {
    ngx_array_t  *links;   /* array di ngx_http_complex_value_t */
} ngx_http_eh_loc_conf_t;


typedef struct {
    unsigned      done:1;  /* gia' tentato per questa richiesta */
} ngx_http_eh_ctx_t;


static ngx_int_t ngx_http_eh_handler(ngx_http_request_t *r);
static void *ngx_http_eh_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_eh_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child);
static char *ngx_http_eh_link(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static ngx_int_t ngx_http_eh_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_eh_commands[] = {

    { ngx_string("early_hints_link"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF
                        |NGX_HTTP_LIF_CONF|NGX_CONF_TAKE1,
      ngx_http_eh_link,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_eh_module_ctx = {
    NULL,                            /* preconfiguration */
    ngx_http_eh_init,                /* postconfiguration */

    NULL,                            /* create main configuration */
    NULL,                            /* init main configuration */

    NULL,                            /* create server configuration */
    NULL,                            /* merge server configuration */

    ngx_http_eh_create_loc_conf,     /* create location configuration */
    ngx_http_eh_merge_loc_conf       /* merge location configuration */
};


ngx_module_t  ngx_http_early_hints_set_module = {
    NGX_MODULE_V1,
    &ngx_http_eh_module_ctx,         /* module context */
    ngx_http_eh_commands,            /* module directives */
    NGX_HTTP_MODULE,                 /* module type */
    NULL,                            /* init master */
    NULL,                            /* init module */
    NULL,                            /* init process */
    NULL,                            /* init thread */
    NULL,                            /* exit thread */
    NULL,                            /* exit process */
    NULL,                            /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_str_t  ngx_http_eh_link_key = ngx_string("Link");


static ngx_int_t
ngx_http_eh_handler(ngx_http_request_t *r)
{
    ngx_int_t                 rc;
    ngx_uint_t                i, n;
    ngx_str_t                 val;
    ngx_table_elt_t          *h, **added;
    ngx_http_eh_ctx_t        *ctx;
    ngx_http_complex_value_t *cv;
    ngx_http_eh_loc_conf_t   *elcf;

    elcf = ngx_http_get_module_loc_conf(r, ngx_http_early_hints_set_module);

    if (elcf->links == NULL || elcf->links->nelts == 0) {
        return NGX_DECLINED;
    }

    /* solo richiesta principale */
    if (r != r->main) {
        return NGX_DECLINED;
    }

    /* il 103 richiede almeno HTTP/1.1 sul transport h1; h2/h3 hanno
     * http_version >= 2.0 e passano comunque. Su HTTP/1.0 saltiamo. */
    if (r->http_version < NGX_HTTP_VERSION_11) {
        return NGX_DECLINED;
    }

    ctx = ngx_http_get_module_ctx(r, ngx_http_early_hints_set_module);
    if (ctx == NULL) {
        ctx = ngx_pcalloc(r->pool, sizeof(ngx_http_eh_ctx_t));
        if (ctx == NULL) {
            return NGX_ERROR;
        }
        ngx_http_set_ctx(r, ctx, ngx_http_early_hints_set_module);
    }

    if (ctx->done) {
        return NGX_DECLINED;
    }
    ctx->done = 1;

    cv = elcf->links->elts;
    n  = elcf->links->nelts;

    added = ngx_palloc(r->pool, sizeof(ngx_table_elt_t *) * n);
    if (added == NULL) {
        return NGX_ERROR;
    }

    /*
     * Inserisce i Link in headers_out.headers. ngx_http_send_early_hints()
     * emettera' come 103 tutte le voci con hash != 0.
     */
    for (i = 0; i < n; i++) {

        if (ngx_http_complex_value(r, &cv[i], &val) != NGX_OK) {
            return NGX_ERROR;
        }

        if (val.len == 0) {
            added[i] = NULL;
            continue;
        }

        h = ngx_list_push(&r->headers_out.headers);
        if (h == NULL) {
            return NGX_ERROR;
        }

        h->hash        = 1;
        h->key         = ngx_http_eh_link_key;
        h->value       = val;
        h->lowcase_key = (u_char *) "link";
        h->next        = NULL;

        added[i] = h;
    }

    /*
     * Invia il 103. La funzione rispetta la direttiva nativa "early_hints"
     * (gate): se non e' configurata o valuta come falsa, ritorna NGX_OK
     * senza inviare nulla. Smista internamente su h1/h2/h3.
     */
    rc = ngx_http_send_early_hints(r);

    /*
     * Neutralizza le voci appena aggiunte (hash = 0) cosi' NON vengono
     * ripetute negli header della risposta finale (200/...). I filtri
     * header del core saltano le voci con hash == 0.
     */
    for (i = 0; i < n; i++) {
        if (added[i] != NULL) {
            added[i]->hash = 0;
        }
    }

    if (rc == NGX_ERROR) {
        return NGX_ERROR;
    }

    /* prosegue il normale processing della richiesta */
    return NGX_DECLINED;
}


static char *
ngx_http_eh_link(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_eh_loc_conf_t *elcf = conf;

    ngx_str_t                        *value;
    ngx_http_complex_value_t         *cv;
    ngx_http_compile_complex_value_t  ccv;

    value = cf->args->elts;

    if (elcf->links == NGX_CONF_UNSET_PTR) {
        elcf->links = ngx_array_create(cf->pool, 4,
                                       sizeof(ngx_http_complex_value_t));
        if (elcf->links == NULL) {
            return NGX_CONF_ERROR;
        }
    }

    cv = ngx_array_push(elcf->links);
    if (cv == NULL) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(&ccv, sizeof(ngx_http_compile_complex_value_t));
    ccv.cf            = cf;
    ccv.value         = &value[1];
    ccv.complex_value = cv;

    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}


static void *
ngx_http_eh_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_eh_loc_conf_t *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_eh_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    conf->links = NGX_CONF_UNSET_PTR;

    return conf;
}


static char *
ngx_http_eh_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_eh_loc_conf_t *prev = parent;
    ngx_http_eh_loc_conf_t *conf = child;

    if (conf->links == NGX_CONF_UNSET_PTR) {
        conf->links = prev->links;
    }

    if (conf->links == NGX_CONF_UNSET_PTR) {
        conf->links = NULL;
    }

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_eh_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    /*
     * Fase PRECONTENT: dopo access/routing, prima che il content handler
     * (proxy_pass, fastcgi, static...) generi la risposta finale. Punto
     * giusto per anticipare il 103.
     */
    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PRECONTENT_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_eh_handler;

    return NGX_OK;
}
