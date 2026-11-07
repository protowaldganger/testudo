//
//  testudo_core.h
//  Testudo
//
//  The whole compression engine behind one small C interface. Each call takes
//  a file's bytes and, if it can make them smaller without breaking the
//  image, returns new bytes in *out (free with tt_free). Thread-safe: every
//  call owns its own state, so files are compressed in parallel.
//

#ifndef TESTUDO_CORE_H
#define TESTUDO_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    TT_SMALLER = 0,      // *out holds a smaller file
    TT_NO_GAIN = 1,      // already as small as we can make it; nothing to write
    TT_UNSUPPORTED = 2,  // not a format, or a variant, this engine handles
    TT_FAILED = 3        // the file could not be read
} tt_result;

typedef enum {
    TT_PNG, TT_JPEG, TT_WEBP, TT_UNKNOWN
} tt_format;

typedef struct {
    int lossy;           // 0: never change a pixel. 1: allow visually-lossless savings.
    int quality;         // 1-100, used when lossy (PNG minimum is quality - 15).
    int keep_metadata;   // 0: strip EXIF/text/thumbnails (colour profile and rotation are always kept).
} tt_options;

tt_format tt_detect(const uint8_t *data, size_t size);
tt_result tt_compress(const uint8_t *data, size_t size, tt_options options,
                      uint8_t **out, size_t *out_size);
void tt_free(void *pointer);

#endif
