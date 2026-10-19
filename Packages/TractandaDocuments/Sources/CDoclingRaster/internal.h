#ifndef TDR_INTERNAL_H
#define TDR_INTERNAL_H
#include "include/CDoclingRaster.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define TDR_DIM 2048
#define TDR_PROFILE_LIMIT (4u * 1024u * 1024u)
struct tdr_session {
    void *context;
    tdr_read read;
    uint64_t length;
    int media;
    void *document;
    void *access;
    int64_t pages;
    int width, height;
};
int tdr_png(tdr_session *, unsigned char **, int *, int *);
int tdr_jpeg(tdr_session *, unsigned char **, int *, int *);
int tdr_orientation(const unsigned char *, size_t);
int tdr_mpf_images(const unsigned char *, size_t);
int tdr_size(int w, int h);
static inline int tdr_get(tdr_session *s, uint64_t pos, void *p, size_t n) {
    return pos <= s->length && n <= s->length - pos && s->read(s->context, pos, p, n);
}
int tdr_srgb16(const unsigned short *, size_t, const void *, size_t, int, double, const double *,
               unsigned char **);
#endif
