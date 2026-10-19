#ifndef TRACTANDA_DOCLING_RASTER_H
#define TRACTANDA_DOCLING_RASTER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Private ABI. Read must fill the entire requested range or return zero. The
 * caller retains descriptor/context and serializes every call through close. */
typedef int (*tdr_read)(void *, uint64_t, unsigned char *, size_t);
typedef struct tdr_session tdr_session;
enum tdr_status {
    TDR_OK = 0,
    TDR_MALFORMED,
    TDR_DECODE,
    TDR_RENDER,
    TDR_DIMENSIONS,
    TDR_FRAMES,
    TDR_ORIENTATION,
    TDR_ENCRYPTED,
    TDR_EMPTY,
    TDR_GEOMETRY,
    TDR_PAGE_RANGE,
    TDR_IO,
    TDR_MEMORY
};
typedef struct {
    double source_width, source_height, source_x, source_y;
    double display_width, display_height, left, top, width, height;
    int rotation, pdf;
} tdr_geometry;
/* media: 1 PDF, 2 PNG, 3 JPEG. Output is always top-down opaque sRGB RGB8. */
int tdr_open(void *context, tdr_read read, uint64_t length, int media, tdr_session **result,
             int64_t *page_count);
int tdr_render(tdr_session *, int64_t page_number, unsigned char *rgb, size_t bytes,
               tdr_geometry *geometry);
void tdr_close(tdr_session *);
const char *tdr_backend_version(void);
#ifdef __cplusplus
}
#endif
#endif
