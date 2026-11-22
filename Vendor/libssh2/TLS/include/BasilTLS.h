// A small TLS client API over OpenSSL's libssl for Basil's FTPS client (ours, not OpenSSL's).
// OpenSSL's own headers use macros Swift cannot import, so Swift calls these instead.
//
// Every call blocks on the socket it was given; the socket's SO_RCVTIMEO and SO_SNDTIMEO
// bound how long. The certificate is not checked here: the caller checks the chain with the
// system trust (Security.framework) before it sends anything.
#ifndef BASIL_TLS_H
#define BASIL_TLS_H

#include <stddef.h>

typedef struct basil_tls basil_tls;

/// Runs a TLS client handshake on a connected socket. `server_name` (may be NULL or an address)
/// is sent as SNI. `resume` (may be NULL) is a connection whose session this one resumes: FTPS
/// data connections resume the control connection's session. Returns NULL and fills `error`
/// on failure. The socket stays owned by the caller.
basil_tls *basil_tls_connect(int fd, const char *server_name, basil_tls *resume,
                             char *error, size_t error_size);

/// Sets up TLS on a connected socket without running the handshake (for a non-blocking socket:
/// call basil_tls_handshake until it returns 1).
basil_tls *basil_tls_start(int fd, const char *server_name, basil_tls *resume, char *error, size_t error_size);

/// One handshake step: 1 done, 0 wants to read, 2 wants to write, -1 failed (`error` filled).
int basil_tls_handshake(basil_tls *tls, char *error, size_t error_size);

/// Bytes read (> 0), 0 at the end of the stream (close_notify or the socket closed), -1 on an
/// error (`error` filled; `timed_out` set to 1 when the socket timeout ran out).
long basil_tls_read(basil_tls *tls, void *buffer, size_t count, int *timed_out, char *error, size_t error_size);

/// Writes everything; returns 0, or -1 on an error.
int basil_tls_write(basil_tls *tls, const void *buffer, size_t count, char *error, size_t error_size);

/// Sends close_notify (does not wait for the peer's).
void basil_tls_shutdown(basil_tls *tls);

void basil_tls_free(basil_tls *tls);

/// The number of certificates the server sent (leaf first), and each one as DER.
int basil_tls_certificate_count(basil_tls *tls);
/// Copies certificate `index` as DER into a new buffer (free with basil_tls_free_buffer).
/// Returns its length, or -1.
int basil_tls_certificate(basil_tls *tls, int index, unsigned char **der);
void basil_tls_free_buffer(unsigned char *buffer);

/// Reads a DER certificate: the subject's common name (or the whole subject), the issuer's
/// common name or organisation, and when it expires (seconds since 1970, 0 when unknown).
/// Returns 0, or -1 when the certificate cannot be read.
int basil_tls_describe_certificate(const unsigned char *der, int length, char *subject, size_t subject_size,
                                   char *issuer, size_t issuer_size, long long *not_after);

/// "TLSv1.3"
const char *basil_tls_version(basil_tls *tls);
/// 1 when the handshake resumed the session it was given.
int basil_tls_resumed(basil_tls *tls);

#endif
