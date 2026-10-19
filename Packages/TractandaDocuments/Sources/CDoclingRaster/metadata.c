#include "internal.h"
int tdr_size(int w, int h) {
    return w > 0 && h > 0 && w <= TDR_DIM && h <= TDR_DIM && w <= 4194304 / h;
}
/* TIFF IFD0 orientation in JPEG APP1 or PNG eXIf. Return 1 by default;
 * any malformed orientation value is rejected instead of being applied. */
static uint16_t u16(const unsigned char *p, int le) {
    return le ? (uint16_t)(p[0] | p[1] << 8) : (uint16_t)(p[0] << 8 | p[1]);
}
static uint32_t u32(const unsigned char *p, int le) {
    return le ? (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24
              : (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
int tdr_orientation(const unsigned char *p, size_t n) {
    if (n < 8)
        return 0;
    int le = p[0] == 'I' && p[1] == 'I';
    if (!le && !(p[0] == 'M' && p[1] == 'M'))
        return 0;
    if (u16(p + 2, le) != 42)
        return 0;
    uint32_t off = u32(p + 4, le);
    if (off > n - 2)
        return 0;
    uint16_t count = u16(p + off, le);
    if (count > (n - off - 2) / 12)
        return 0;
    int orientation = 1, found = 0;
    for (size_t i = 0; i < count; i++) {
        const unsigned char *q = p + off + 2 + 12 * i;
        if (u16(q, le) == 0x112) {
            if (found++ || u16(q + 2, le) != 3 || u32(q + 4, le) != 1)
                return 0;
            orientation = u16(q + 8, le);
        }
    }
    return orientation;
}

int tdr_mpf_images(const unsigned char *p, size_t n) {
    if (n < 8)
        return 0;
    int le = p[0] == 'I' && p[1] == 'I';
    if (!le && !(p[0] == 'M' && p[1] == 'M'))
        return 0;
    if (u16(p + 2, le) != 42)
        return 0;
    uint32_t off = u32(p + 4, le);
    if (off > n - 2)
        return 0;
    uint16_t count = u16(p + off, le);
    if (count > (n - off - 2) / 12)
        return 0;
    for (size_t i = 0; i < count; i++) {
        const unsigned char *q = p + off + 2 + 12 * i;
        if (u16(q, le) == 0xb001) {
            if (u16(q + 2, le) != 4 || u32(q + 4, le) != 1)
                return 0;
            uint32_t frames = u32(q + 8, le);
            return frames == 1 ? 1 : 2;
        }
    }
    return 0;
}
