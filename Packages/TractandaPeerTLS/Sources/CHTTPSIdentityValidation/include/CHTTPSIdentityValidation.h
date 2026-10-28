#ifndef TRACTANDA_HTTPS_IDENTITY_VALIDATION_H
#define TRACTANDA_HTTPS_IDENTITY_VALIDATION_H
#include <stdint.h>
#include <stddef.h>
// PEM buffers are bounded by the Swift caller. No ownership crosses this interface.
// Results: 1 success; -1 parse; -2 validity; -3 SAN; -4 usage; -5 key; -6 chain.
int tractanda_https_validate(const uint8_t *chain, size_t chain_len,
    const uint8_t *key, size_t key_len, const uint8_t *roots, size_t roots_len,
    int verify_chain, const char *hostname, int64_t now, int64_t *valid_from, int64_t *expires);
#endif
