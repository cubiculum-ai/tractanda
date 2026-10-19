// jpeglib's public API requires FILE and size_t from the caller.
#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>

#include "internal.h"
#include <jpeglib.h>

// Error identifiers follow the JPEG public type declarations.
#include <jerror.h>
typedef struct {
    struct jpeg_decompress_struct jpeg;
    struct jpeg_error_mgr errors;
    struct jpeg_source_mgr source;
    jmp_buf jump;
    tdr_session *session;
    uint64_t offset;
    unsigned char buffer[16384];
    unsigned short *pixels;
    void *row;
    unsigned char *icc;
    size_t icc_bytes;
    int error, created;
} jpeg_state;
static void jpeg_error(j_common_ptr p) {
    jpeg_state *s = (jpeg_state *)p;
    longjmp(s->jump, 1);
}
static void jpeg_message(j_common_ptr p, int level) {
    if (level < 0)
        jpeg_error(p);
}
static void jpeg_init(j_decompress_ptr p) { (void)p; }
static void jpeg_term(j_decompress_ptr p) { (void)p; }
static boolean jpeg_fill(j_decompress_ptr p) {
    jpeg_state *s = (jpeg_state *)p;
    if (s->offset >= s->session->length) {
        s->error = TDR_DECODE;
        ERREXIT(p, JERR_INPUT_EOF);
    }
    size_t n = (size_t)fmin(sizeof(s->buffer), s->session->length - s->offset);
    if (!tdr_get(s->session, s->offset, s->buffer, n)) {
        s->error = TDR_IO;
        ERREXIT(p, JERR_FILE_READ);
    }
    s->offset += n;
    s->source.next_input_byte = s->buffer;
    s->source.bytes_in_buffer = n;
    return TRUE;
}
static void jpeg_skip(j_decompress_ptr p, long n) {
    if (n <= 0)
        return;
    jpeg_state *s = (jpeg_state *)p;
    size_t available = s->source.bytes_in_buffer;
    if ((unsigned long)n <= available) {
        s->source.next_input_byte += n;
        s->source.bytes_in_buffer -= n;
        return;
    }
    uint64_t skip = (uint64_t)n - available;
    if (skip > s->session->length - s->offset) {
        s->error = TDR_DECODE;
        ERREXIT(p, JERR_INPUT_EOF);
    }
    s->offset += skip;
    s->source.bytes_in_buffer = 0;
}
static uint16_t be16(const unsigned char *p) { return (uint16_t)(p[0] << 8 | p[1]); }
/* Parse only metadata marker headers before SOS; never save unbounded marker
 * lists in libjpeg's permanent pool. ICC segments require exact order/count. */
static int metadata(jpeg_state *s) {
    uint64_t pos = 2;
    unsigned char **parts = calloc(256, sizeof(*parts));
    size_t lengths[256] = {0}, total = 0;
    int wanted = 0, found = 0, e = TDR_OK;
    if (!parts)
        return TDR_MEMORY;
    while (pos < s->session->length) {
        unsigned char h[4];
        if (!tdr_get(s->session, pos, h, 2) || h[0] != 255) {
            e = TDR_MALFORMED;
            break;
        }
        while (h[1] == 255) {
            pos++;
            if (!tdr_get(s->session, pos, h, 2)) {
                e = TDR_MALFORMED;
                break;
            }
        }
        if (e)
            break;
        int marker = h[1];
        pos += 2;
        if (marker == 0xda || marker == 0xd9)
            break;
        if (marker == 0 || marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) {
            e = TDR_MALFORMED;
            break;
        }
        if (marker == 1)
            continue;
        if (!tdr_get(s->session, pos, h, 2)) {
            e = TDR_MALFORMED;
            break;
        }
        size_t n = be16(h);
        if (n < 2 || n > s->session->length - pos) {
            e = TDR_MALFORMED;
            break;
        }
        if ((marker == 0xe1 || marker == 0xe2) && n > 2) {
            unsigned char *data = malloc(n - 2);
            if (!data) {
                e = TDR_MEMORY;
                break;
            }
            if (!tdr_get(s->session, pos + 2, data, n - 2)) {
                free(data);
                e = TDR_IO;
                break;
            }
            if (marker == 0xe1 && n >= 8 && !memcmp(data, "Exif\0\0", 6) &&
                tdr_orientation(data + 6, n - 8) != 1)
                e = TDR_ORIENTATION;
            if (marker == 0xe2 && n >= 16 && !memcmp(data, "ICC_PROFILE\0", 12)) {
                int index = data[12], count = data[13];
                size_t bytes = n - 16;
                if (!index || !count || index > count || (wanted && count != wanted) ||
                    parts[index] || bytes > TDR_PROFILE_LIMIT - total)
                    e = TDR_DECODE;
                else {
                    wanted = count;
                    parts[index] = malloc(bytes ? bytes : 1);
                    if (!parts[index])
                        e = TDR_MEMORY;
                    else {
                        memcpy(parts[index], data + 14, bytes);
                        lengths[index] = bytes;
                        total += bytes;
                        found++;
                    }
                }
            }
            /* MPO's MPF IFD is not silently treated as a single image. */
            if (marker == 0xe2 && n >= 6 && !memcmp(data, "MPF\0", 4)) {
                int frames = tdr_mpf_images(data + 4, n - 6);
                if (frames != 1)
                    e = frames == 2 ? TDR_FRAMES : TDR_MALFORMED;
            }
            free(data);
            if (e)
                break;
        }
        pos += n;
    }
    if (!e && wanted) {
        if (found != wanted || !total)
            e = TDR_DECODE;
        else {
            s->icc = malloc(total ? total : 1);
            if (!s->icc)
                e = TDR_MEMORY;
            else {
                size_t off = 0;
                for (int i = 1; i <= wanted; i++) {
                    memcpy(s->icc + off, parts[i], lengths[i]);
                    off += lengths[i];
                }
                s->icc_bytes = total;
            }
        }
    }
    for (int i = 0; i < 256; i++)
        free(parts[i]);
    free(parts);
    return e;
}
int tdr_jpeg(tdr_session *session, unsigned char **result, int *width, int *height) {
    *result = NULL;
    jpeg_state *s = calloc(1, sizeof(*s));
    if (!s)
        return TDR_MEMORY;
    s->session = session;
    s->error = TDR_DECODE;
    int e = metadata(s);
    if (e) {
        free(s->icc);
        free(s);
        return e;
    }
    s->jpeg.err = jpeg_std_error(&s->errors);
    s->errors.error_exit = jpeg_error;
    s->errors.emit_message = jpeg_message;
    if (setjmp(s->jump)) {
        e = s->error;
        goto done;
    }
    jpeg_create_decompress(&s->jpeg);
    s->created = 1;
    s->source.init_source = jpeg_init;
    s->source.fill_input_buffer = jpeg_fill;
    s->source.skip_input_data = jpeg_skip;
    s->source.resync_to_restart = jpeg_resync_to_restart;
    s->source.term_source = jpeg_term;
    s->jpeg.src = &s->source;
    if (jpeg_read_header(&s->jpeg, TRUE) != JPEG_HEADER_OK) {
        e = TDR_MALFORMED;
        goto done;
    }
    if (!tdr_size((int)s->jpeg.image_width, (int)s->jpeg.image_height)) {
        e = TDR_DIMENSIONS;
        goto done;
    }
    int cmyk = s->jpeg.jpeg_color_space == JCS_CMYK || s->jpeg.jpeg_color_space == JCS_YCCK;
    s->jpeg.out_color_space = cmyk ? JCS_CMYK : JCS_RGB;
    s->jpeg.dct_method = JDCT_ISLOW;
    s->jpeg.do_fancy_upsampling = TRUE;
    int precision = s->jpeg.data_precision;
    if (precision != 8 && precision != 12 && precision != 16) {
        e = TDR_DECODE;
        goto done;
    }
    if (!jpeg_start_decompress(&s->jpeg)) {
        e = TDR_DECODE;
        goto done;
    }
    int w = (int)s->jpeg.output_width, h = (int)s->jpeg.output_height,
        channels = s->jpeg.output_components;
    if (!tdr_size(w, h) || channels != (cmyk ? 4 : 3)) {
        e = TDR_DIMENSIONS;
        goto done;
    }
    s->pixels = malloc((size_t)w * h * 8);
    s->row = malloc((size_t)w * channels * (precision == 8 ? 1 : 2));
    if (!s->pixels || !s->row) {
        e = TDR_MEMORY;
        goto done;
    }
    unsigned maximum = (1u << precision) - 1;
    while (s->jpeg.output_scanline < s->jpeg.output_height) {
        size_t row = s->jpeg.output_scanline;
        JDIMENSION got;
        if (precision == 8) {
            JSAMPROW p = s->row;
            got = jpeg_read_scanlines(&s->jpeg, &p, 1);
        } else if (precision == 12) {
            J12SAMPROW p = s->row;
            got = jpeg12_read_scanlines(&s->jpeg, &p, 1);
        } else {
            J16SAMPROW p = s->row;
            got = jpeg16_read_scanlines(&s->jpeg, &p, 1);
        }
        if (got != 1) {
            e = TDR_DECODE;
            goto done;
        }
        for (int x = 0; x < w; x++)
            for (int c = 0; c < 4; c++) {
                unsigned value =
                    c < channels ? (precision == 8 ? ((unsigned char *)s->row)[x * channels + c]
                                                   : ((unsigned short *)s->row)[x * channels + c])
                                 : maximum;
                if (cmyk && s->jpeg.saw_Adobe_marker)
                    value = maximum - value;
                s->pixels[((size_t)row * w + x) * 4 + c] =
                    (unsigned short)(((uint64_t)value * 65535 + maximum / 2) / maximum);
            }
    }
    if (!jpeg_finish_decompress(&s->jpeg)) {
        e = TDR_DECODE;
        goto done;
    }
    e = tdr_srgb16(s->pixels, (size_t)w * h, s->icc, s->icc_bytes, cmyk, 0, NULL, result);
    if (!e) {
        *width = w;
        *height = h;
    }
done:
    if (s->created)
        jpeg_destroy_decompress(&s->jpeg);
    free(s->row);
    free(s->pixels);
    free(s->icc);
    free(s);
    return e;
}
