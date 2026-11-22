// See include/BasilTLS.h.
#include "BasilTLS.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <arpa/inet.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

struct basil_tls {
    SSL *ssl;
};

static SSL_CTX *shared_context;
static pthread_once_t context_once = PTHREAD_ONCE_INIT;

static void make_context(void) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return;
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    // Checked by the caller against the system trust.
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY);
    // Sessions are kept by the connection that made them (SSL_get1_session), not a cache.
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT | SSL_SESS_CACHE_NO_INTERNAL_STORE);
    shared_context = ctx;
}

static void describe(char *error, size_t size, const char *what, SSL *ssl, int rc) {
    if (!error || size == 0) return;
    unsigned long code = ERR_get_error();
    char detail[256] = "";
    if (code != 0) {
        ERR_error_string_n(code, detail, sizeof detail);
    } else if (ssl) {
        int reason = SSL_get_error(ssl, rc);
        if (reason == SSL_ERROR_SYSCALL) {
            snprintf(detail, sizeof detail, "%s", errno ? strerror(errno) : "the connection was closed");
        } else if (reason == SSL_ERROR_ZERO_RETURN) {
            snprintf(detail, sizeof detail, "the server closed the TLS connection");
        } else {
            snprintf(detail, sizeof detail, "TLS error %d", reason);
        }
    }
    snprintf(error, size, "%s: %s", what, detail);
    ERR_clear_error();
}

static int is_address(const char *name) {
    unsigned char buffer[16];
    return inet_pton(AF_INET, name, buffer) == 1 || inet_pton(AF_INET6, name, buffer) == 1;
}

basil_tls *basil_tls_start(int fd, const char *server_name, basil_tls *resume, char *error, size_t error_size) {
    pthread_once(&context_once, make_context);
    ERR_clear_error();
    if (!shared_context) {
        describe(error, error_size, "TLS could not be set up", NULL, 0);
        return NULL;
    }
    SSL *ssl = SSL_new(shared_context);
    if (!ssl) {
        describe(error, error_size, "TLS could not be set up", NULL, 0);
        return NULL;
    }
    if (server_name && *server_name && !is_address(server_name)) {
        SSL_set_tlsext_host_name(ssl, server_name);
    }
    if (resume && resume->ssl) {
        SSL_SESSION *session = SSL_get1_session(resume->ssl);
        if (session) {
            SSL_set_session(ssl, session);
            SSL_SESSION_free(session);
        }
    }
    SSL_set_fd(ssl, fd);
    basil_tls *tls = calloc(1, sizeof *tls);
    if (!tls) {
        SSL_free(ssl);
        return NULL;
    }
    tls->ssl = ssl;
    return tls;
}

int basil_tls_handshake(basil_tls *tls, char *error, size_t error_size) {
    ERR_clear_error();
    errno = 0;
    int rc = SSL_connect(tls->ssl);
    if (rc == 1) return 1;
    int reason = SSL_get_error(tls->ssl, rc);
    if (reason == SSL_ERROR_WANT_READ) return 0;
    if (reason == SSL_ERROR_WANT_WRITE) return 2;
    describe(error, error_size, "The TLS handshake failed", tls->ssl, rc);
    return -1;
}

basil_tls *basil_tls_connect(int fd, const char *server_name, basil_tls *resume, char *error, size_t error_size) {
    basil_tls *tls = basil_tls_start(fd, server_name, resume, error, error_size);
    if (!tls) return NULL;
    int rc = basil_tls_handshake(tls, error, error_size);
    if (rc != 1) {
        // A blocking socket only stops early when its timeout ran out.
        if (rc != -1) snprintf(error, error_size, "The TLS handshake failed: the server did not answer in time");
        basil_tls_free(tls);
        return NULL;
    }
    return tls;
}

long basil_tls_read(basil_tls *tls, void *buffer, size_t count, int *timed_out, char *error, size_t error_size) {
    if (timed_out) *timed_out = 0;
    ERR_clear_error();
    size_t got = 0;
    errno = 0;
    int rc = SSL_read_ex(tls->ssl, buffer, count, &got);
    if (rc == 1) return (long)got;
    int reason = SSL_get_error(tls->ssl, rc);
    if (reason == SSL_ERROR_ZERO_RETURN) return 0;
    // A peer that closes the socket without close_notify: the end of the stream for FTP, whose
    // replies say whether a transfer was complete.
    if (reason == SSL_ERROR_SYSCALL && errno == 0) {
        ERR_clear_error();
        return 0;
    }
    if (reason == SSL_ERROR_SSL && ERR_GET_REASON(ERR_peek_error()) == SSL_R_UNEXPECTED_EOF_WHILE_READING) {
        ERR_clear_error();
        return 0;
    }
    if ((reason == SSL_ERROR_SYSCALL || reason == SSL_ERROR_WANT_READ) && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        if (timed_out) *timed_out = 1;
    }
    describe(error, error_size, "Reading over TLS failed", tls->ssl, rc);
    return -1;
}

int basil_tls_write(basil_tls *tls, const void *buffer, size_t count, char *error, size_t error_size) {
    const unsigned char *bytes = buffer;
    while (count > 0) {
        ERR_clear_error();
        size_t written = 0;
        errno = 0;
        int rc = SSL_write_ex(tls->ssl, bytes, count, &written);
        if (rc != 1) {
            describe(error, error_size, "Writing over TLS failed", tls->ssl, rc);
            return -1;
        }
        bytes += written;
        count -= written;
    }
    return 0;
}

void basil_tls_shutdown(basil_tls *tls) {
    if (tls && tls->ssl) {
        SSL_shutdown(tls->ssl);
        ERR_clear_error();
    }
}

void basil_tls_free(basil_tls *tls) {
    if (!tls) return;
    if (tls->ssl) SSL_free(tls->ssl);
    free(tls);
}

int basil_tls_certificate_count(basil_tls *tls) {
    STACK_OF(X509) *chain = SSL_get_peer_cert_chain(tls->ssl);
    return chain ? sk_X509_num(chain) : 0;
}

int basil_tls_certificate(basil_tls *tls, int index, unsigned char **der) {
    STACK_OF(X509) *chain = SSL_get_peer_cert_chain(tls->ssl);
    if (!chain || index < 0 || index >= sk_X509_num(chain)) return -1;
    *der = NULL;
    return i2d_X509(sk_X509_value(chain, index), der);
}

void basil_tls_free_buffer(unsigned char *buffer) { OPENSSL_free(buffer); }

static void name_entry(X509_NAME *name, int nid, char *out, size_t size) {
    int index = X509_NAME_get_index_by_NID(name, nid, -1);
    if (index < 0) return;
    ASN1_STRING *data = X509_NAME_ENTRY_get_data(X509_NAME_get_entry(name, index));
    unsigned char *utf8 = NULL;
    int length = ASN1_STRING_to_UTF8(&utf8, data);
    if (length < 0) return;
    snprintf(out, size, "%.*s", length, utf8);
    OPENSSL_free(utf8);
}

int basil_tls_describe_certificate(const unsigned char *der, int length, char *subject, size_t subject_size,
                                   char *issuer, size_t issuer_size, long long *not_after) {
    const unsigned char *cursor = der;
    X509 *cert = d2i_X509(NULL, &cursor, length);
    if (!cert) {
        ERR_clear_error();
        return -1;
    }
    if (subject_size) subject[0] = 0;
    if (issuer_size) issuer[0] = 0;
    name_entry(X509_get_subject_name(cert), NID_commonName, subject, subject_size);
    if (subject_size && !subject[0]) X509_NAME_oneline(X509_get_subject_name(cert), subject, (int)subject_size);
    name_entry(X509_get_issuer_name(cert), NID_commonName, issuer, issuer_size);
    if (issuer_size && !issuer[0]) name_entry(X509_get_issuer_name(cert), NID_organizationName, issuer, issuer_size);
    if (issuer_size && !issuer[0]) X509_NAME_oneline(X509_get_issuer_name(cert), issuer, (int)issuer_size);
    *not_after = 0;
    struct tm when;
    if (ASN1_TIME_to_tm(X509_get0_notAfter(cert), &when) == 1) *not_after = (long long)timegm(&when);
    X509_free(cert);
    ERR_clear_error();
    return 0;
}

const char *basil_tls_version(basil_tls *tls) { return SSL_get_version(tls->ssl); }

int basil_tls_resumed(basil_tls *tls) { return SSL_session_reused(tls->ssl); }
