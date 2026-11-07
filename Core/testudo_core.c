//
//  testudo_core.c
//  Testudo
//
//  PNG:  lodepng re-encodes losslessly in the smallest colour type it can
//        prove is exact, trying three filter strategies. Lossy mode adds
//        libimagequant (pngquant's engine) and keeps whichever is smaller.
//  JPEG: mozjpeg rewrites the existing coefficients (optimised Huffman tables,
//        progressive scans), so no pixel changes. Lossy mode also re-encodes
//        at the chosen quality, but only when the original is above it.
//  WebP: libwebp re-encodes lossless files losslessly; lossy mode re-encodes
//        lossy ones. Either way metadata can be stripped without re-encoding.
//
//  Colour profiles and photo rotation always survive, so nothing looks
//  different afterwards. Everything runs in memory; nothing touches the disk.
//

#include "testudo_core.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lodepng.h"
#include "libdeflate.h"
#include "libimagequant.h"
#include "jpeglib.h"
#include "webp/decode.h"
#include "webp/encode.h"
#include "webp/mux.h"
#include "webp/demux.h"

void tt_free(void *pointer) { free(pointer); }

tt_format tt_detect(const uint8_t *d, size_t n) {
    if (n >= 8 && memcmp(d, "\x89PNG\r\n\x1a\n", 8) == 0) return TT_PNG;
    if (n >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return TT_JPEG;
    if (n >= 12 && memcmp(d, "RIFF", 4) == 0 && memcmp(d + 8, "WEBP", 4) == 0) return TT_WEBP;
    return TT_UNKNOWN;
}

// Keeps the smallest candidate in (*best, *best_size); frees the loser.
static void keep_smaller(uint8_t **best, size_t *best_size, uint8_t *candidate, size_t candidate_size,
                         void (*release)(void *)) {
    if (candidate && candidate_size && (!*best || candidate_size < *best_size)) {
        if (*best) free(*best);
        // Normalise ownership: everything returned to the caller is malloc'd.
        if (release != free) {
            uint8_t *copy = malloc(candidate_size);
            if (!copy) { release(candidate); return; }
            memcpy(copy, candidate, candidate_size);
            release(candidate);
            candidate = copy;
        }
        *best = candidate;
        *best_size = candidate_size;
    } else if (candidate) {
        release(candidate);
    }
}

// EXIF orientation tag (0x0112); 1 when absent or unreadable. Takes the TIFF
// block with or without JPEG's "Exif\0\0" prefix (WebP stores it without).
static int exif_orientation(const uint8_t *d, size_t n) {
    if (n >= 6 && memcmp(d, "Exif\0\0", 6) == 0) { d += 6; n -= 6; }
    if (n < 8 || !((d[0] == 'I' && d[1] == 'I') || (d[0] == 'M' && d[1] == 'M'))) return 1;
    int le = d[0] == 'I';
    #define U16(p) (le ? (unsigned)((p)[0] | (p)[1] << 8) : (unsigned)((p)[0] << 8 | (p)[1]))
    #define U32(p) (le ? ((unsigned)(p)[0] | (unsigned)(p)[1] << 8 | (unsigned)(p)[2] << 16 | (unsigned)(p)[3] << 24) \
                       : ((unsigned)(p)[0] << 24 | (unsigned)(p)[1] << 16 | (unsigned)(p)[2] << 8 | (unsigned)(p)[3]))
    size_t ifd = U32(d + 4);
    if (ifd + 2 > n) return 1;
    unsigned count = U16(d + ifd);
    for (unsigned i = 0; i < count; i++) {
        size_t entry = ifd + 2 + (size_t)i * 12;
        if (entry + 12 > n) break;
        if (U16(d + entry) == 0x0112) return (int)U16(d + entry + 8);
    }
    #undef U16
    #undef U32
    return 1;
}

// MARK: - PNG

static void png_keep_only_colour_chunks(LodePNGInfo *info, int keep_metadata) {
    if (keep_metadata) return;
    lodepng_clear_text(info);
    lodepng_clear_itext(info);
    info->time_defined = 0;
    info->phys_defined = 0;
    info->background_defined = 0;
    for (int i = 0; i < 3; i++) {
        free(info->unknown_chunks_data[i]);
        info->unknown_chunks_data[i] = NULL;
        info->unknown_chunks_size[i] = 0;
    }
}

// libdeflate replaces lodepng's own deflate: far faster at a better ratio.
// Filter strategies are compared at a quick level, then only the winner is
// compressed hard, which is most of the gain for a fraction of the time.
#ifndef TT_TRIAL_LEVEL
#define TT_TRIAL_LEVEL 2
#endif
#ifndef TT_FINAL_LEVEL
#define TT_FINAL_LEVEL 11
#endif

static unsigned png_deflate(unsigned char **out, size_t *out_size, const unsigned char *in,
                            size_t in_size, const LodePNGCompressSettings *settings) {
    int level = settings->custom_context ? *(const int *)settings->custom_context : TT_FINAL_LEVEL;
    struct libdeflate_compressor *compressor = libdeflate_alloc_compressor(level);
    if (!compressor) return 83;
    size_t bound = libdeflate_zlib_compress_bound(compressor, in_size);
    *out = malloc(bound);
    if (!*out) { libdeflate_free_compressor(compressor); return 83; }
    *out_size = libdeflate_zlib_compress(compressor, in, in_size, *out, bound);
    libdeflate_free_compressor(compressor);
    return *out_size ? 0 : 111;
}

static unsigned png_inflate(unsigned char **out, size_t *out_size, const unsigned char *in,
                            size_t in_size, const LodePNGDecompressSettings *settings) {
    struct libdeflate_decompressor *decompressor = libdeflate_alloc_decompressor();
    if (!decompressor) return 83;
    // lodepng passes the exact expected size when it knows it.
    size_t capacity = settings->max_output_size ? settings->max_output_size : in_size * 4 + 1024;
    for (;;) {
        *out = malloc(capacity);
        if (!*out) { libdeflate_free_decompressor(decompressor); return 83; }
        size_t produced = 0;
        enum libdeflate_result r = libdeflate_zlib_decompress(decompressor, in, in_size, *out, capacity, &produced);
        if (r == LIBDEFLATE_SUCCESS) {
            *out_size = produced;
            libdeflate_free_decompressor(decompressor);
            return 0;
        }
        free(*out);
        *out = NULL;
        if (r != LIBDEFLATE_INSUFFICIENT_SPACE || capacity > ((size_t)1 << 31)) {
            libdeflate_free_decompressor(decompressor);
            return 95;
        }
        capacity *= 2;
    }
}

static void png_encoder_settings(LodePNGState *state) {
    state->encoder.auto_convert = 1;             // smallest exact colour type and bit depth
    state->encoder.zlibsettings.custom_zlib = png_deflate;
    state->encoder.add_id = 0;
    state->encoder.text_compression = 1;
}

static void png_decoder_settings(LodePNGState *state) {
    state->decoder.zlibsettings.custom_zlib = png_inflate;
    state->decoder.zlibsettings.ignore_adler32 = 0;
}

static unsigned char *png_encode(const unsigned char *pixels, unsigned w, unsigned h,
                                 const LodePNGColorMode *raw, const LodePNGInfo *info,
                                 LodePNGFilterStrategy strategy, int level, size_t *size) {
    LodePNGState state;
    lodepng_state_init(&state);
    png_encoder_settings(&state);
    state.encoder.filter_strategy = strategy;
    state.encoder.zlibsettings.custom_context = &level;
    unsigned char *png = NULL;
    *size = 0;
    if (lodepng_color_mode_copy(&state.info_raw, raw) != 0 ||
        lodepng_info_copy(&state.info_png, info) != 0 ||
        lodepng_encode(&png, size, pixels, w, h, &state) != 0) {
        free(png);
        png = NULL;
        *size = 0;
    }
    lodepng_state_cleanup(&state);
    return png;
}

// Finds the filter strategy that compresses best at a quick level, then
// encodes with it at full strength. Keeps the result if it is the smallest.
static void png_encode_best(const unsigned char *pixels, unsigned w, unsigned h,
                            const LodePNGColorMode *raw, const LodePNGInfo *info,
                            uint8_t **best, size_t *best_size) {
    static const LodePNGFilterStrategy strategies[] = { LFS_MINSUM, LFS_ENTROPY, LFS_ZERO };
    LodePNGFilterStrategy winner = LFS_MINSUM;
    size_t winner_size = 0;
    for (int i = 0; i < 3; i++) {
        size_t size;
        unsigned char *trial = png_encode(pixels, w, h, raw, info, strategies[i], TT_TRIAL_LEVEL, &size);
        if (trial && (!winner_size || size < winner_size)) {
            winner = strategies[i];
            winner_size = size;
        }
        free(trial);
    }
    if (!winner_size) return;
    size_t size;
    unsigned char *png = png_encode(pixels, w, h, raw, info, winner, TT_FINAL_LEVEL, &size);
    keep_smaller(best, best_size, png, size, free);
}

static void png_quantize(const uint8_t *data, size_t size, const LodePNGInfo *info,
                         int quality, uint8_t **best, size_t *best_size) {
    unsigned char *rgba = NULL;
    unsigned w, h;
    LodePNGState decoder;
    lodepng_state_init(&decoder);
    png_decoder_settings(&decoder);
    decoder.info_raw.colortype = LCT_RGBA;
    decoder.info_raw.bitdepth = 8;
    unsigned failed = lodepng_decode(&rgba, &w, &h, &decoder, data, size);
    lodepng_state_cleanup(&decoder);
    if (failed) { free(rgba); return; }

    liq_attr *attr = liq_attr_create();
    liq_image *image = NULL;
    liq_result *result = NULL;
    unsigned char *indices = NULL;
    int minimum = quality > 15 ? quality - 15 : 0;
    if (!attr || liq_set_quality(attr, minimum, quality) != LIQ_OK) goto done;
    liq_set_speed(attr, 4);
    image = liq_image_create_rgba(attr, rgba, (int)w, (int)h, 0);
    if (!image || liq_image_quantize(image, attr, &result) != LIQ_OK) goto done;
    liq_set_dithering_level(result, 1.0f);
    indices = malloc((size_t)w * h);
    if (!indices || liq_write_remapped_image(result, image, indices, (size_t)w * h) != LIQ_OK) goto done;

    const liq_palette *palette = liq_get_palette(result);
    LodePNGColorMode raw;
    lodepng_color_mode_init(&raw);
    raw.colortype = LCT_PALETTE;
    raw.bitdepth = 8;
    for (unsigned i = 0; i < palette->count; i++) {
        lodepng_palette_add(&raw, palette->entries[i].r, palette->entries[i].g,
                            palette->entries[i].b, palette->entries[i].a);
    }
    png_encode_best(indices, w, h, &raw, info, best, best_size);
    lodepng_color_mode_cleanup(&raw);

done:
    free(indices);
    if (result) liq_result_destroy(result);
    if (image) liq_image_destroy(image);
    if (attr) liq_attr_destroy(attr);
    free(rgba);
}

static tt_result compress_png(const uint8_t *data, size_t size, tt_options o, uint8_t **out, size_t *out_size) {
    LodePNGState state;
    lodepng_state_init(&state);
    png_decoder_settings(&state);
    state.decoder.color_convert = 0;   // pixels exactly as stored
    state.decoder.remember_unknown_chunks = 1;
    unsigned char *pixels = NULL;
    unsigned w, h;
    if (lodepng_decode(&pixels, &w, &h, &state, data, size) != 0) {
        free(pixels);
        lodepng_state_cleanup(&state);
        return TT_FAILED;
    }
    png_keep_only_colour_chunks(&state.info_png, o.keep_metadata);

    uint8_t *best = NULL;
    size_t best_size = 0;
    png_encode_best(pixels, w, h, &state.info_png.color, &state.info_png, &best, &best_size);
    free(pixels);
    if (o.lossy) png_quantize(data, size, &state.info_png, o.quality, &best, &best_size);
    lodepng_state_cleanup(&state);

    // Read fine but could not be written back exactly (say, a colour profile
    // the PNG format does not allow): leave the file as it is.
    if (!best) return TT_NO_GAIN;
    if (best_size >= size) { free(best); return TT_NO_GAIN; }
    *out = best;
    *out_size = best_size;
    return TT_SMALLER;
}

// MARK: - JPEG

typedef struct {
    struct jpeg_error_mgr base;
    jmp_buf escape;
} jpeg_error;

static void jpeg_fail(j_common_ptr info) {
    longjmp(((jpeg_error *)info->err)->escape, 1);
}

static void jpeg_quiet(j_common_ptr info) { (void)info; }

static int marker_worth_keeping(jpeg_saved_marker_ptr m, int keep_metadata) {
    if (m->marker == JPEG_APP0) return 0;                      // JFIF: the library writes its own
    if (m->marker == JPEG_APP0 + 14) return 0;                 // Adobe: written when needed
    if (keep_metadata) return 1;
    if (m->marker == JPEG_APP0 + 2 && m->data_length >= 12 &&
        memcmp(m->data, "ICC_PROFILE", 12) == 0) return 1;     // colour profile
    if (m->marker == JPEG_APP0 + 1 && exif_orientation(m->data, m->data_length) != 1) return 1; // rotation
    return 0;
}

static void jpeg_save_all_markers(j_decompress_ptr d) {
    jpeg_save_markers(d, JPEG_COM, 0xFFFF);
    for (int i = 0; i < 16; i++) jpeg_save_markers(d, JPEG_APP0 + i, 0xFFFF);
}

static void jpeg_copy_markers(j_decompress_ptr src, j_compress_ptr dst, int keep_metadata) {
    for (jpeg_saved_marker_ptr m = src->marker_list; m; m = m->next) {
        if (marker_worth_keeping(m, keep_metadata)) {
            jpeg_write_marker(dst, m->marker, m->data, m->data_length);
        }
    }
}

// Rough quality the file was saved at, from its luminance table (IJG scale).
static int jpeg_estimated_quality(j_decompress_ptr d) {
    static const unsigned standard[64] = {
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99 };
    JQUANT_TBL *table = d->quant_tbl_ptrs[0];
    if (!table) return 100;
    double sum = 0, reference = 0;
    for (int i = 0; i < 64; i++) { sum += table->quantval[i]; reference += standard[i]; }
    double scale = sum * 100.0 / reference;          // percent of the q50 table
    int q = scale <= 100 ? (int)((200.0 - scale) / 2.0 + 0.5) : (int)(5000.0 / scale + 0.5);
    return q < 1 ? 1 : q > 100 ? 100 : q;
}

static void jpeg_lossless(const uint8_t *data, size_t size, int keep_metadata,
                          uint8_t **best, size_t *best_size, int *quality_out, int *colourful) {
    struct jpeg_decompress_struct src;
    struct jpeg_compress_struct dst;
    jpeg_error src_err, dst_err;
    unsigned char *volatile buffer = NULL;
    unsigned long buffer_size = 0;
    volatile int dst_created = 0;

    src.err = jpeg_std_error(&src_err.base);
    src_err.base.error_exit = jpeg_fail;
    src_err.base.output_message = jpeg_quiet;
    dst.err = jpeg_std_error(&dst_err.base);
    dst_err.base.error_exit = jpeg_fail;
    dst_err.base.output_message = jpeg_quiet;

    if (setjmp(src_err.escape) || setjmp(dst_err.escape)) goto done;

    jpeg_create_decompress(&src);
    jpeg_mem_src(&src, data, (unsigned long)size);
    jpeg_save_all_markers(&src);
    jpeg_read_header(&src, TRUE);
    *quality_out = jpeg_estimated_quality(&src);
    *colourful = src.jpeg_color_space == JCS_YCbCr || src.jpeg_color_space == JCS_GRAYSCALE
              || src.jpeg_color_space == JCS_RGB;
    jvirt_barray_ptr *coefficients = jpeg_read_coefficients(&src);

    jpeg_create_compress(&dst);
    dst_created = 1;
    jpeg_copy_critical_parameters(&src, &dst);
    dst.optimize_coding = TRUE;
    jpeg_simple_progression(&dst);
    jpeg_mem_dest(&dst, (unsigned char **)&buffer, &buffer_size);
    jpeg_write_coefficients(&dst, coefficients);
    jpeg_copy_markers(&src, &dst, keep_metadata);
    jpeg_finish_compress(&dst);
    jpeg_finish_decompress(&src);

    keep_smaller(best, best_size, (uint8_t *)buffer, buffer_size, free);
    buffer = NULL;

done:
    free((void *)buffer);
    if (dst_created) jpeg_destroy_compress(&dst);
    jpeg_destroy_decompress(&src);
}

static void jpeg_lossy(const uint8_t *data, size_t size, int quality, int keep_metadata,
                       uint8_t **best, size_t *best_size) {
    struct jpeg_decompress_struct src;
    struct jpeg_compress_struct dst;
    jpeg_error src_err, dst_err;
    unsigned char *volatile buffer = NULL;
    unsigned long buffer_size = 0;
    JSAMPLE *volatile row = NULL;
    volatile int dst_created = 0;

    src.err = jpeg_std_error(&src_err.base);
    src_err.base.error_exit = jpeg_fail;
    src_err.base.output_message = jpeg_quiet;
    dst.err = jpeg_std_error(&dst_err.base);
    dst_err.base.error_exit = jpeg_fail;
    dst_err.base.output_message = jpeg_quiet;

    if (setjmp(src_err.escape) || setjmp(dst_err.escape)) goto done;

    jpeg_create_decompress(&src);
    jpeg_mem_src(&src, data, (unsigned long)size);
    jpeg_save_all_markers(&src);
    jpeg_read_header(&src, TRUE);
    src.out_color_space = src.num_components == 1 ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_start_decompress(&src);

    jpeg_create_compress(&dst);
    dst_created = 1;
    dst.image_width = src.output_width;
    dst.image_height = src.output_height;
    dst.input_components = src.output_components;
    dst.in_color_space = src.out_color_space;
    jpeg_set_defaults(&dst);                 // mozjpeg: trellis, optimised progressive scans
    jpeg_set_quality(&dst, quality, TRUE);
    dst.density_unit = src.density_unit;
    dst.X_density = src.X_density;
    dst.Y_density = src.Y_density;
    jpeg_mem_dest(&dst, (unsigned char **)&buffer, &buffer_size);
    jpeg_start_compress(&dst, TRUE);
    jpeg_copy_markers(&src, &dst, keep_metadata);

    row = malloc((size_t)src.output_width * src.output_components);
    if (!row) goto done;
    while (src.output_scanline < src.output_height) {
        JSAMPLE *line = row;
        jpeg_read_scanlines(&src, &line, 1);
        jpeg_write_scanlines(&dst, &line, 1);
    }
    jpeg_finish_compress(&dst);
    jpeg_finish_decompress(&src);

    keep_smaller(best, best_size, (uint8_t *)buffer, buffer_size, free);
    buffer = NULL;

done:
    free((void *)row);
    free((void *)buffer);
    if (dst_created) jpeg_destroy_compress(&dst);
    jpeg_destroy_decompress(&src);
}

static tt_result compress_jpeg(const uint8_t *data, size_t size, tt_options o, uint8_t **out, size_t *out_size) {
    uint8_t *best = NULL;
    size_t best_size = 0;
    int source_quality = 100, colourful = 0;
    jpeg_lossless(data, size, o.keep_metadata, &best, &best_size, &source_quality, &colourful);
    if (!best) return TT_FAILED;
    // Re-encoding a file already at or below the target only stacks artefacts.
    if (o.lossy && colourful && source_quality > o.quality) {
        jpeg_lossy(data, size, o.quality, o.keep_metadata, &best, &best_size);
    }
    if (best_size >= size) { free(best); return TT_NO_GAIN; }
    *out = best;
    *out_size = best_size;
    return TT_SMALLER;
}

// MARK: - WebP

static void webp_release(void *pointer) { WebPFree(pointer); }

// The same image without EXIF/XMP: no re-encoding at all.
static void webp_strip(const uint8_t *data, size_t size, int keep_metadata, uint8_t **best, size_t *best_size) {
    if (keep_metadata) return;
    WebPData whole = { data, size };
    WebPMux *mux = WebPMuxCreate(&whole, 0);
    if (!mux) return;
    WebPData exif;
    if (WebPMuxGetChunk(mux, "EXIF", &exif) == WEBP_MUX_OK &&
        exif_orientation(exif.bytes, exif.size) == 1) {
        WebPMuxDeleteChunk(mux, "EXIF");
    }
    WebPMuxDeleteChunk(mux, "XMP ");
    WebPData assembled = { NULL, 0 };
    if (WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK) {
        keep_smaller(best, best_size, (uint8_t *)assembled.bytes, assembled.size, webp_release);
    } else {
        WebPDataClear(&assembled);
    }
    WebPMuxDelete(mux);
}

// A freshly encoded file plus the original's colour profile (and metadata).
static void webp_wrap(const uint8_t *encoded, size_t encoded_size, WebPDemuxer *source,
                      int keep_metadata, uint8_t **best, size_t *best_size) {
    WebPMux *mux = WebPMuxNew();
    if (!mux) return;
    WebPData image = { encoded, encoded_size };
    WebPMuxError status = WebPMuxSetImage(mux, &image, 1);
    static const char *const kept[] = { "ICCP", "EXIF", "XMP " };
    for (int i = 0; i < 3 && status == WEBP_MUX_OK; i++) {
        WebPChunkIterator chunk;
        if (!WebPDemuxGetChunk(source, kept[i], 1, &chunk)) continue;
        int wanted = keep_metadata || i == 0 ||        // colour profile always
            (i == 1 && exif_orientation(chunk.chunk.bytes, chunk.chunk.size) != 1);  // rotation
        if (wanted) status = WebPMuxSetChunk(mux, kept[i], &chunk.chunk, 1);
        WebPDemuxReleaseChunkIterator(&chunk);
    }
    WebPData assembled = { NULL, 0 };
    if (status == WEBP_MUX_OK && WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK) {
        keep_smaller(best, best_size, (uint8_t *)assembled.bytes, assembled.size, webp_release);
    } else {
        WebPDataClear(&assembled);
    }
    WebPMuxDelete(mux);
}

static void webp_encode(const WebPDecoderConfig *decoded, int lossless, int quality,
                        WebPDemuxer *source, int keep_metadata, uint8_t **best, size_t *best_size) {
    WebPConfig config;
    WebPPicture picture;
    WebPMemoryWriter writer;
    if (!WebPConfigInit(&config) || !WebPPictureInit(&picture)) return;
    if (lossless) {
        WebPConfigLosslessPreset(&config, 6);
        config.exact = 0;            // colours under fully transparent pixels may change; nothing visible does
    } else {
        config.quality = (float)quality;
        config.method = 5;
        config.alpha_quality = 100;
    }
    config.thread_level = 0;          // files already run in parallel
    picture.use_argb = lossless;
    picture.width = decoded->output.width;
    picture.height = decoded->output.height;
    const WebPRGBABuffer *rgba = &decoded->output.u.RGBA;
    int ok = WebPPictureImportRGBA(&picture, rgba->rgba, rgba->stride);
    WebPMemoryWriterInit(&writer);
    picture.writer = WebPMemoryWrite;
    picture.custom_ptr = &writer;
    if (ok && WebPEncode(&config, &picture)) {
        webp_wrap(writer.mem, writer.size, source, keep_metadata, best, best_size);
    }
    WebPMemoryWriterClear(&writer);
    WebPPictureFree(&picture);
}

static tt_result compress_webp(const uint8_t *data, size_t size, tt_options o, uint8_t **out, size_t *out_size) {
    WebPBitstreamFeatures features;
    if (WebPGetFeatures(data, size, &features) != VP8_STATUS_OK) return TT_FAILED;
    if (features.has_animation) return TT_UNSUPPORTED;

    WebPData whole = { data, size };
    WebPDemuxer *source = WebPDemux(&whole);
    if (!source) return TT_FAILED;

    uint8_t *best = NULL;
    size_t best_size = 0;

    webp_strip(data, size, o.keep_metadata, &best, &best_size);

    int lossless = features.format == 2;
    if (lossless || o.lossy) {
        WebPDecoderConfig decoded;
        if (WebPInitDecoderConfig(&decoded)) {
            decoded.output.colorspace = MODE_RGBA;
            if (WebPDecode(data, size, &decoded) == VP8_STATUS_OK) {
                webp_encode(&decoded, lossless, o.quality, source, o.keep_metadata, &best, &best_size);
            }
            WebPFreeDecBuffer(&decoded.output);
        }
    }
    WebPDemuxDelete(source);

    if (!best) return TT_FAILED;
    if (best_size >= size) { free(best); return TT_NO_GAIN; }
    *out = best;
    *out_size = best_size;
    return TT_SMALLER;
}

// MARK: -

tt_result tt_compress(const uint8_t *data, size_t size, tt_options options,
                      uint8_t **out, size_t *out_size) {
    *out = NULL;
    *out_size = 0;
    if (options.quality < 1) options.quality = 1;
    if (options.quality > 100) options.quality = 100;
    switch (tt_detect(data, size)) {
    case TT_PNG: return compress_png(data, size, options, out, out_size);
    case TT_JPEG: return compress_jpeg(data, size, options, out, out_size);
    case TT_WEBP: return compress_webp(data, size, options, out, out_size);
    default: return TT_UNSUPPORTED;
    }
}
