#include "internal.h"
#include <png.h>
#include <setjmp.h>
typedef struct {
    tdr_session *session;
    uint64_t offset;
    int error;
    unsigned short *pixels;
    png_structp png;
    png_infop info;
} png_state;
static void png_failure(png_structp p, png_const_charp message) {
    (void)message;
    png_state *s = png_get_error_ptr(p);
    longjmp(png_jmpbuf(p), 1);
    (void)s;
}
static void tdr_png_warning(png_structp p, png_const_charp message) {
    (void)p;
    (void)message;
}
static void png_input(png_structp p, png_bytep output, png_size_t n) {
    png_state *s = png_get_io_ptr(p);
    if (!tdr_get(s->session, s->offset, output, n)) {
        s->error = TDR_IO;
        png_error(p, "positional read failed");
    }
    s->offset += n;
}
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
/* APNG is not exposed as an unnoticed first frame. Inspect chunk headers with
 * positional reads, no compressed/original-file buffer or ancillary allocation. */
static int png_frames(tdr_session *s) {
    uint64_t pos = 8;
    unsigned char h[12];
    while (pos < s->length) {
        if (!tdr_get(s, pos, h, 8))
            return TDR_MALFORMED;
        uint32_t n = be32(h);
        if (n > s->length - pos - 8 || n + 12ULL > s->length - pos)
            return TDR_MALFORMED;
        if (!memcmp(h + 4, "acTL", 4)) {
            if (n != 8 || !tdr_get(s, pos + 8, h, 8))
                return TDR_MALFORMED;
            if (be32(h) != 1)
                return TDR_FRAMES;
        }
        if (!memcmp(h + 4, "eXIf", 4)) {
            if (n > TDR_PROFILE_LIMIT)
                return TDR_DECODE;
            unsigned char *exif = malloc(n ? n : 1);
            if (!exif)
                return TDR_MEMORY;
            int valid = tdr_get(s, pos + 8, exif, n) && tdr_orientation(exif, n) == 1;
            free(exif);
            if (!valid)
                return TDR_ORIENTATION;
        }
        if (!memcmp(h + 4, "IEND", 4))
            return n == 0 ? TDR_OK : TDR_MALFORMED;
        pos += 12ULL + n;
    }
    return TDR_MALFORMED;
}
int tdr_png(tdr_session *s, unsigned char **result, int *width, int *height) {
    *result = NULL;
    int e = png_frames(s);
    if (e)
        return e;
    png_state *state = calloc(1, sizeof(*state));
    if (!state)
        return TDR_MEMORY;
    state->session = s;
    state->error = TDR_DECODE;
    state->png = png_create_read_struct(PNG_LIBPNG_VER_STRING, state, png_failure, tdr_png_warning);
    if (!state->png) {
        free(state);
        return TDR_MEMORY;
    }
    state->info = png_create_info_struct(state->png);
    if (!state->info) {
        png_destroy_read_struct(&state->png, NULL, NULL);
        free(state);
        return TDR_MEMORY;
    }
    if (setjmp(png_jmpbuf(state->png))) {
        e = state->error;
        goto done;
    }
    png_set_read_fn(state->png, state, png_input);
    png_set_user_limits(state->png, TDR_DIM, TDR_DIM);
    png_set_chunk_malloc_max(state->png, TDR_PROFILE_LIMIT);
    png_set_chunk_cache_max(state->png, 64);
    png_set_crc_action(state->png, PNG_CRC_ERROR_QUIT, PNG_CRC_ERROR_QUIT);
    png_read_info(state->png, state->info);
    png_uint_32 w = png_get_image_width(state->png, state->info),
                h = png_get_image_height(state->png, state->info);
    if (w > TDR_DIM || h > TDR_DIM || !tdr_size((int)w, (int)h)) {
        e = TDR_DIMENSIONS;
        goto done;
    }
    png_bytep exif = NULL;
    png_uint_32 exif_len = 0;
    if (png_get_eXIf_1(state->png, state->info, &exif_len, &exif) &&
        tdr_orientation(exif, exif_len) != 1) {
        e = TDR_ORIENTATION;
        goto done;
    }
    png_charp profile_name = NULL;
    int compression = 0;
    png_bytep icc = NULL;
    png_uint_32 icc_len = 0;
    png_get_iCCP(state->png, state->info, &profile_name, &compression, &icc, &icc_len);
    double gamma = 0, chrm[8];
    const double *calibration = NULL;
    int intent = 0;
    if (!icc_len && !png_get_sRGB(state->png, state->info, &intent)) {
        png_get_gAMA(state->png, state->info, &gamma);
        if (png_get_cHRM(state->png, state->info, &chrm[0], &chrm[1], &chrm[2], &chrm[3], &chrm[4],
                         &chrm[5], &chrm[6], &chrm[7]))
            calibration = chrm;
    }
    int type = png_get_color_type(state->png, state->info),
        depth = png_get_bit_depth(state->png, state->info);
    int alpha =
        (type & PNG_COLOR_MASK_ALPHA) || png_get_valid(state->png, state->info, PNG_INFO_tRNS);
    if (type == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(state->png);
    if (type == PNG_COLOR_TYPE_GRAY && depth < 8)
        png_set_expand_gray_1_2_4_to_8(state->png);
    if (png_get_valid(state->png, state->info, PNG_INFO_tRNS))
        png_set_tRNS_to_alpha(state->png);
    if (type == PNG_COLOR_TYPE_GRAY || type == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(state->png);
    png_set_expand_16(state->png);
    if (!alpha)
        png_set_add_alpha(state->png, 65535, PNG_FILLER_AFTER);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    png_set_swap(state->png);
#endif
    int passes = png_set_interlace_handling(state->png);
    png_read_update_info(state->png, state->info);
    if (png_get_rowbytes(state->png, state->info) != (size_t)w * 8 ||
        png_get_bit_depth(state->png, state->info) != 16 ||
        png_get_channels(state->png, state->info) != 4) {
        e = TDR_DECODE;
        goto done;
    }
    state->pixels = calloc((size_t)w * h, 8);
    if (!state->pixels) {
        e = TDR_MEMORY;
        goto done;
    }
    for (int pass = 0; pass < passes; pass++)
        for (png_uint_32 row = 0; row < h; row++)
            png_read_row(state->png, (png_bytep)(state->pixels + (size_t)row * w * 4), NULL);
    png_read_end(state->png, NULL);
    e = tdr_srgb16(state->pixels, (size_t)w * h, icc, icc_len, 0, gamma, calibration, result);
    if (!e) {
        *width = (int)w;
        *height = (int)h;
    }
done:
    free(state->pixels);
    png_destroy_read_struct(&state->png, &state->info, NULL);
    free(state);
    return e;
}
