#include "CHTTPSIdentityValidation.h"
#include <CNIOBoringSSL_bio.h>
#include <CNIOBoringSSL_pem.h>
#include <CNIOBoringSSL_x509.h>
#include <CNIOBoringSSL_x509v3.h>
#include <CNIOBoringSSL_err.h>
#include <string.h>

int tractanda_https_validate(const uint8_t *chain, size_t chain_len,
    const uint8_t *key, size_t key_len, const uint8_t *roots, size_t roots_len,
    int verify_chain, const char *hostname, int64_t now, int64_t *valid_from, int64_t *expires) {
    int result = -1;
    BIO *bio = BIO_new_mem_buf(chain, (int)chain_len);
    X509 *leaf = NULL;
    STACK_OF(X509) *intermediates = sk_X509_new_null();
    X509_STORE *store = NULL;
    X509_STORE_CTX *ctx = NULL;
    EVP_PKEY *private_key = NULL;
    if (!bio || !intermediates) goto done;
    leaf = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    if (!leaf) goto done;
    for (;;) {
        X509 *next = PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (!next) break;
        if (!sk_X509_push(intermediates, next)) { X509_free(next); goto done; }
    }
    ERR_clear_error();
    if (!ASN1_TIME_to_posix(X509_get0_notBefore(leaf), valid_from) ||
        !ASN1_TIME_to_posix(X509_get0_notAfter(leaf), expires)) goto done;
    if (now < *valid_from || now >= *expires) { result = -2; goto done; }
    if (X509_check_host(leaf, hostname, strlen(hostname),
            X509_CHECK_FLAG_NEVER_CHECK_SUBJECT | X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS, NULL) != 1) {
        result = -3; goto done;
    }
    if ((X509_get_extension_flags(leaf) & (EXFLAG_INVALID | EXFLAG_CA | EXFLAG_CRITICAL)) ||
        !(X509_get_key_usage(leaf) & X509v3_KU_DIGITAL_SIGNATURE) ||
        !(X509_get_extended_key_usage(leaf) & XKU_SSL_SERVER) ||
        X509_check_purpose(leaf, X509_PURPOSE_SSL_SERVER, 0) != 1) {
        result = -4; goto done;
    }
    // A server identity need not chain to the server host's own trust roots.
    // Every supplied issuer must follow and cryptographically sign its predecessor.
    X509 *previous = leaf;
    for (size_t i = 0; i < sk_X509_num(intermediates); i++) {
        X509 *issuer = sk_X509_value(intermediates, i);
        int64_t issuer_starts, issuer_expires;
        if (!ASN1_TIME_to_posix(X509_get0_notBefore(issuer), &issuer_starts) ||
            !ASN1_TIME_to_posix(X509_get0_notAfter(issuer), &issuer_expires)) goto done;
        if (now < issuer_starts || now >= issuer_expires) { result = -2; goto done; }
        if (issuer_starts > *valid_from) *valid_from = issuer_starts;
        if (issuer_expires < *expires) *expires = issuer_expires;
        if (X509_check_ca(issuer) != 1 || X509_check_purpose(issuer, X509_PURPOSE_SSL_SERVER, 1) != 1) { result = -6; goto done; }
        EVP_PKEY *public_key = X509_get_pubkey(issuer);
        int valid = public_key && X509_check_issued(issuer, previous) == X509_V_OK && X509_verify(previous, public_key) == 1;
        EVP_PKEY_free(public_key);
        if (!valid) { result = -6; goto done; }
        previous = issuer;
    }
    if (key) {
        BIO *keybio = BIO_new_mem_buf(key, (int)key_len);
        // No password callback or interactive encrypted-key fallback.
        if (keybio) { private_key = PEM_read_bio_PrivateKey(keybio, NULL, NULL, ""); BIO_free(keybio); }
        if (!private_key || X509_check_private_key(leaf, private_key) != 1) { result = -5; goto done; }
    }
    if (verify_chain) {
        result = -6;
        store = X509_STORE_new(); ctx = X509_STORE_CTX_new();
        if (!store || !ctx) goto done;
        if (roots) {
            BIO *rootbio = BIO_new_mem_buf(roots, (int)roots_len);
            int count = 0;
            if (!rootbio) goto done;
            for (;;) {
                X509 *root = PEM_read_bio_X509(rootbio, NULL, NULL, NULL);
                if (!root) break;
                if (X509_STORE_add_cert(store, root) == 1) count++;
                X509_free(root);
            }
            BIO_free(rootbio); ERR_clear_error();
            if (!count) goto done;
        } else if (X509_STORE_set_default_paths(store) != 1) goto done;
        if (X509_STORE_CTX_init(ctx, store, leaf, intermediates) != 1 ||
            X509_STORE_CTX_set_purpose(ctx, X509_PURPOSE_SSL_SERVER) != 1) goto done;
        X509_STORE_CTX_set_time_posix(ctx, 0, now);
        if (X509_verify_cert(ctx) != 1) goto done;
    }
    result = 1;
done:
    EVP_PKEY_free(private_key); X509_STORE_CTX_free(ctx); X509_STORE_free(store);
    sk_X509_pop_free(intermediates, X509_free); X509_free(leaf); BIO_free(bio);
    ERR_clear_error();
    return result;
}
