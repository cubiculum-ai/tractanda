#include "internal.h"
#include <lcms2.h>
static void quiet(cmsContext c, cmsUInt32Number code, const char *message) {
    (void)c;
    (void)code;
    (void)message;
}
/* Four unpremultiplied uint16 channels; RGB+A or CMYK. ICC conversion precedes
 * white alpha composition. No global LCMS settings or shared mutable profiles. */
int tdr_srgb16(const unsigned short *pixels, size_t count, const void *icc, size_t icc_bytes,
               int cmyk, double gamma, const double *chrm, unsigned char **result) {
    *result = NULL;
    if (!count || count > 4194304 || icc_bytes > TDR_PROFILE_LIMIT)
        return TDR_DECODE;
    cmsContext context = cmsCreateContext(NULL, NULL);
    if (!context)
        return TDR_MEMORY;
    cmsSetLogErrorHandlerTHR(context, quiet);
    cmsHPROFILE source = NULL, destination = NULL;
    cmsHTRANSFORM transform = NULL;
    unsigned short *converted = NULL, *gray = NULL;
    int e = TDR_OK;
    if (icc_bytes) {
        source = cmsOpenProfileFromMemTHR(context, icc, (cmsUInt32Number)icc_bytes);
        if (!source)
            e = TDR_DECODE;
    } else if (!cmyk) {
        if (gamma > 0 || chrm) {
            cmsCIExyY white = {.3127, .3290, 1};
            cmsCIExyYTRIPLE primaries = {{.64, .33, 1}, {.30, .60, 1}, {.15, .06, 1}};
            if (chrm) {
                white.x = chrm[0];
                white.y = chrm[1];
                primaries.Red.x = chrm[2];
                primaries.Red.y = chrm[3];
                primaries.Green.x = chrm[4];
                primaries.Green.y = chrm[5];
                primaries.Blue.x = chrm[6];
                primaries.Blue.y = chrm[7];
            }
            cmsToneCurve *curves[3] = {0};
            for (int i = 0; i < 3; i++)
                curves[i] = cmsBuildGamma(context, gamma > 0 ? 1 / gamma : 2.2);
            if (curves[0] && curves[1] && curves[2])
                source = cmsCreateRGBProfileTHR(context, &white, &primaries, curves);
            for (int i = 0; i < 3; i++)
                if (curves[i])
                    cmsFreeToneCurve(curves[i]);
        } else
            source = cmsCreate_sRGBProfileTHR(context);
        if (!source)
            e = TDR_DECODE;
    }
    if (!e && source) {
        cmsColorSpaceSignature signature = cmsGetColorSpace(source);
        cmsUInt32Number type = cmyk ? TYPE_CMYK_16 : TYPE_RGBA_16;
        if (cmyk && signature != cmsSigCmykData)
            e = TDR_DECODE;
        else if (!cmyk && signature == cmsSigGrayData) {
            gray = malloc(count * sizeof(*gray));
            if (!gray)
                e = TDR_MEMORY;
            else {
                for (size_t i = 0; i < count; i++)
                    gray[i] = pixels[4 * i];
                type = TYPE_GRAY_16;
            }
        } else if (!cmyk && signature != cmsSigRgbData)
            e = TDR_DECODE;
        destination = cmsCreate_sRGBProfileTHR(context);
        if (!destination)
            e = TDR_MEMORY;
        if (!e) {
            transform = cmsCreateTransformTHR(context, source, type, destination, TYPE_RGB_16,
                                              INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE);
            if (!transform)
                e = TDR_DECODE;
        }
        if (!e) {
            converted = malloc(count * 3 * sizeof(*converted));
            if (!converted)
                e = TDR_MEMORY;
            else
                cmsDoTransform(transform, gray ? gray : pixels, converted, (cmsUInt32Number)count);
        }
    }
    unsigned char *out = NULL;
    if (!e) {
        out = malloc(count * 3);
        if (!out)
            e = TDR_MEMORY;
    }
    if (!e)
        for (size_t i = 0; i < count; i++)
            for (size_t c = 0; c < 3; c++) {
                uint64_t v;
                if (converted)
                    v = converted[3 * i + c];
                else { /* Unprofiled DeviceCMYK: multiplicative white/black coverage. */
                    v = ((uint64_t)(65535 - pixels[4 * i + c]) * (65535 - pixels[4 * i + 3]) +
                         32767) /
                        65535;
                }
                if (!cmyk) {
                    uint64_t alpha = pixels[4 * i + 3];
                    v = (v * alpha + 65535 * (65535 - alpha) + 32767) / 65535;
                }
                out[3 * i + c] = (unsigned char)((v + 128) / 257);
            }
    if (transform)
        cmsDeleteTransform(transform);
    if (source)
        cmsCloseProfile(source);
    if (destination)
        cmsCloseProfile(destination);
    cmsDeleteContext(context);
    free(converted);
    free(gray);
    if (e)
        free(out);
    else
        *result = out;
    return e;
}
