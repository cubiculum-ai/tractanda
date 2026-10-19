#include "internal.h"
#include <fpdf_edit.h>
#include <fpdf_transformpage.h>
#include <fpdfview.h>
#include <limits.h>
#include <pthread.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
/* PDFium initialization is process-lifetime. Do not destroy its global state
 * while another descriptor-backed session may still exist. */
static pthread_mutex_t pdf_lock = PTHREAD_MUTEX_INITIALIZER;
static void initialize(void) {
    FPDF_LIBRARY_CONFIG c = {0};
    c.version = 2;
    FPDF_InitLibraryWithConfig(&c);
}
static int pdf_read(void *p, unsigned long pos, unsigned char *buffer, unsigned long n) {
    return tdr_get((tdr_session *)p, (uint64_t)pos, buffer, (size_t)n);
}
const char *tdr_backend_version(void) { return "tractanda.linux-raster.v1-pdfium-agg-srgb"; }
int tdr_open(void *context, tdr_read read, uint64_t length, int media, tdr_session **result,
             int64_t *count) {
    if (!result || !count || !read || !length || length > ULONG_MAX)
        return TDR_IO;
    *result = NULL;
    *count = 0;
    tdr_session *s = calloc(1, sizeof(*s));
    if (!s)
        return TDR_MEMORY;
    s->context = context;
    s->read = read;
    s->length = length;
    s->media = media;
    int error = TDR_OK;
    if (media == 1) {
        FPDF_FILEACCESS *access = calloc(1, sizeof(*access));
        if (!access) {
            free(s);
            return TDR_MEMORY;
        }
        s->access = access;
        access->m_FileLen = (unsigned long)length;
        access->m_GetBlock = pdf_read;
        access->m_Param = s;
        pthread_mutex_lock(&pdf_lock);
        pthread_once(&once, initialize);
        s->document = FPDF_LoadCustomDocument(access, NULL);
        if (!s->document)
            error = FPDF_GetLastError() == FPDF_ERR_PASSWORD ? TDR_ENCRYPTED : TDR_MALFORMED;
        else if (FPDF_GetSecurityHandlerRevision(s->document) >= 0)
            error = TDR_ENCRYPTED;
        else {
            s->pages = FPDF_GetPageCount(s->document);
            if (s->pages <= 0)
                error = TDR_EMPTY;
        }
        pthread_mutex_unlock(&pdf_lock);
    } else if (media == 2 || media == 3) {
        /* Decode and release one bounded image for admission. No page-array/original
         * buffering; later rendering decodes from the retained descriptor again. */
        unsigned char *rgb = NULL;
        error = media == 2 ? tdr_png(s, &rgb, &s->width, &s->height)
                           : tdr_jpeg(s, &rgb, &s->width, &s->height);
        free(rgb);
        s->pages = 1;
    } else
        error = TDR_MALFORMED;
    if (error) {
        tdr_close(s);
        return error;
    }
    *result = s;
    *count = s->pages;
    return TDR_OK;
}
void tdr_close(tdr_session *s) {
    if (!s)
        return;
    if (s->document) {
        pthread_mutex_lock(&pdf_lock);
        FPDF_CloseDocument(s->document);
        pthread_mutex_unlock(&pdf_lock);
    }
    free(s->access);
    free(s);
}
static int placement(tdr_geometry *g) {
    double w = g->display_width, h = g->display_height;
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0 || w > 100000 || h > 100000)
        return TDR_GEOMETRY;
    double scale = fmin(TDR_DIM / w, TDR_DIM / h);
    g->width = w * scale;
    g->height = h * scale;
    g->left = (TDR_DIM - g->width) / 2;
    g->top = (TDR_DIM - g->height) / 2;
    return TDR_OK;
}
/* Separable Catmull-Rom high-quality renderer interpolation. This is raster
 * backend behavior; model-facing Pillow Lanczos/normalization stays unchanged.
 * White outside the declared rectangle, clamp source edge samples inside it. */
static double cubic(double x) {
    x = fabs(x);
    if (x < 1)
        return 1.5 * x * x * x - 2.5 * x * x + 1;
    if (x < 2)
        return -.5 * x * x * x + 2.5 * x * x - 4 * x + 2;
    return 0;
}
static int image_canvas(unsigned char *out, const unsigned char *in, int w, int h,
                        const tdr_geometry *g) {
    size_t row_size = (size_t)TDR_DIM * h * 3;
    float *horizontal = malloc(row_size * sizeof(float));
    if (!horizontal)
        return TDR_MEMORY;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < TDR_DIM; x++) {
            double p = ((x + .5 - g->left) / g->width) * w - .5;
            int first = (int)floor(p) - 1;
            for (int c = 0; c < 3; c++) {
                double v = 0, total = 0;
                for (int k = 0; k < 4; k++) {
                    int ix = first + k;
                    double weight = cubic(p - ix);
                    if (ix < 0)
                        ix = 0;
                    if (ix >= w)
                        ix = w - 1;
                    v += in[((size_t)y * w + ix) * 3 + c] * weight;
                    total += weight;
                }
                horizontal[((size_t)y * TDR_DIM + x) * 3 + c] = (float)(v / total);
            }
        }
    memset(out, 255, (size_t)TDR_DIM * TDR_DIM * 3);
    for (int y = 0; y < TDR_DIM; y++)
        for (int x = 0; x < TDR_DIM; x++) {
            if (x + .5 < g->left || x + .5 >= g->left + g->width || y + .5 < g->top ||
                y + .5 >= g->top + g->height)
                continue;
            double p = ((y + .5 - g->top) / g->height) * h - .5;
            int first = (int)floor(p) - 1;
            for (int c = 0; c < 3; c++) {
                double v = 0, total = 0;
                for (int k = 0; k < 4; k++) {
                    int iy = first + k;
                    double weight = cubic(p - iy);
                    if (iy < 0)
                        iy = 0;
                    if (iy >= h)
                        iy = h - 1;
                    v += horizontal[((size_t)iy * TDR_DIM + x) * 3 + c] * weight;
                    total += weight;
                }
                v = floor(v / total + .5);
                out[((size_t)y * TDR_DIM + x) * 3 + c] = (unsigned char)fmax(0, fmin(255, v));
            }
        }
    free(horizontal);
    return TDR_OK;
}
int tdr_render(tdr_session *s, int64_t number, unsigned char *rgb, size_t bytes, tdr_geometry *g) {
    if (!s || !rgb || !g || bytes != (size_t)TDR_DIM * TDR_DIM * 3)
        return TDR_RENDER;
    if (number < 1 || number > s->pages)
        return TDR_PAGE_RANGE;
    memset(g, 0, sizeof(*g));
    if (s->media != 1) {
        unsigned char *image = NULL;
        int w = 0, h = 0;
        int e = s->media == 2 ? tdr_png(s, &image, &w, &h) : tdr_jpeg(s, &image, &w, &h);
        if (e)
            return e;
        if (w != s->width || h != s->height) {
            free(image);
            return TDR_DECODE;
        }
        g->source_width = g->display_width = w;
        g->source_height = g->display_height = h;
        e = placement(g);
        if (!e)
            e = image_canvas(rgb, image, w, h, g);
        free(image);
        return e;
    }
    pthread_mutex_lock(&pdf_lock);
    FPDF_PAGE page = FPDF_LoadPage(s->document, (int)(number - 1));
    int e = TDR_OK;
    if (!page) {
        pthread_mutex_unlock(&pdf_lock);
        return TDR_MALFORMED;
    }
    float l = 0, b = 0, r = 0, t = 0;
    if (!FPDFPage_GetCropBox(page, &l, &b, &r, &t) && !FPDFPage_GetMediaBox(page, &l, &b, &r, &t))
        e = TDR_GEOMETRY;
    int rotation = FPDFPage_GetRotation(page);
    if (rotation < 0 || rotation > 3)
        e = TDR_GEOMETRY;
    g->source_x = l;
    g->source_y = b;
    g->source_width = (double)r - l;
    g->source_height = (double)t - b;
    g->rotation = rotation * 90;
    g->pdf = 1;
    if (!isfinite(l) || !isfinite(b) || fabs(l) > 100000 || fabs(b) > 100000 ||
        g->source_width <= 0 || g->source_height <= 0 || g->source_width > 100000 ||
        g->source_height > 100000)
        e = TDR_GEOMETRY;
    g->display_width = (rotation & 1) ? g->source_height : g->source_width;
    g->display_height = (rotation & 1) ? g->source_width : g->source_height;
    if (!e)
        e = placement(g);
    unsigned char *pixels = NULL;
    FPDF_BITMAP bitmap = NULL;
    if (!e) {
        pixels = malloc((size_t)TDR_DIM * TDR_DIM * 4);
        if (!pixels)
            e = TDR_MEMORY;
        else
            memset(pixels, 255, (size_t)TDR_DIM * TDR_DIM * 4);
    }
    if (!e) {
        bitmap = FPDFBitmap_CreateEx(TDR_DIM, TDR_DIM, FPDFBitmap_BGRx, pixels, TDR_DIM * 4);
        if (!bitmap)
            e = TDR_RENDER;
    }
    if (!e) {
        FPDFBitmap_FillRect(bitmap, 0, 0, TDR_DIM, TDR_DIM, 0xffffffff);
        /* WithMatrix composes PDFium's intrinsic crop/rotation/top-down display
         * matrix first. Apply only fit/centering here; repeating user-space rotation
         * would rotate twice. Match CGPDFPageGetDrawingTransform's documented media
         * intersection, natural-size centering and scale-down-only behavior, followed
         * by the converter's existing explicit fit scale for the raw crop rectangle. */
        double effective_width = FPDF_GetPageWidthF(page),
               effective_height = FPDF_GetPageHeightF(page);
        double z = g->width / g->display_width;
        double x = g->left + (g->width - effective_width * z) / 2;
        double y = g->top + (g->height - effective_height * z) / 2;
        FS_MATRIX matrix = {(float)z, 0, 0, (float)z, (float)x, (float)y};
        FS_RECTF clip = {(float)fmax(g->left, x), (float)fmax(g->top, y),
                         (float)fmin(g->left + g->width, x + effective_width * z),
                         (float)fmin(g->top + g->height, y + effective_height * z)};
        if (!isfinite(matrix.a) || !isfinite(matrix.d) || !isfinite(matrix.e) ||
            !isfinite(matrix.f) || !isfinite(effective_width) || !isfinite(effective_height) ||
            effective_width <= 0 || effective_height <= 0)
            e = TDR_GEOMETRY;
        else {
            FPDF_RenderPageBitmapWithMatrix(bitmap, page, &matrix, &clip, 0);
            for (size_t i = 0; i < (size_t)TDR_DIM * TDR_DIM; i++) {
                rgb[3 * i] = pixels[4 * i + 2];
                rgb[3 * i + 1] = pixels[4 * i + 1];
                rgb[3 * i + 2] = pixels[4 * i];
            }
        }
    }
    if (bitmap)
        FPDFBitmap_Destroy(bitmap);
    free(pixels);
    FPDF_ClosePage(page);
    pthread_mutex_unlock(&pdf_lock);
    return e;
}
