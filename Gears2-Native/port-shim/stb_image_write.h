// A stand-in for the one stb_image_write function the ports use.
//
// Why this file exists: three layer-0 files (#include "stb_image_write.h") write PNG screenshots and buffer dumps,
// and COGBox gets that header from a pinned NVIDIA FLIP checkout (third_party/flip/src/cpp/tool) that is not in the
// repository. On macOS we need something that satisfies the same call sites without pulling FLIP in, so this is a
// small, self-contained PNG writer with the identical signature and the same STB_IMAGE_WRITE_IMPLEMENTATION contract
// as the original: the declarations are always visible, and the code is emitted in whichever translation unit
// defines the macro (frame_capture.cpp does).
//
// The encoder writes uncompressed ("stored") deflate blocks inside a normal zlib stream: every PNG reader accepts it,
// the files are just larger than stb's. Screenshots and debug dumps are not shipped, so size does not matter here.
//
// Drop-in compatible: stbi_write_png(name, w, h, comp, data, stride) -> non-zero on success.
#ifndef COGBOX_MAC_STB_IMAGE_WRITE_H
#define COGBOX_MAC_STB_IMAGE_WRITE_H

#ifdef __cplusplus
extern "C" {
#endif

int stbi_write_png(char const *filename, int w, int h, int comp, const void *data, int stride_in_bytes);

#ifdef __cplusplus
}
#endif

#endif  // COGBOX_MAC_STB_IMAGE_WRITE_H

#ifdef STB_IMAGE_WRITE_IMPLEMENTATION
#ifndef COGBOX_MAC_STB_IMAGE_WRITE_IMPL
#define COGBOX_MAC_STB_IMAGE_WRITE_IMPL

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

static uint32_t stbiw__crc_table[256];
static int stbiw__crc_ready = 0;

static void stbiw__crc_init(void) {
  for (uint32_t n = 0; n < 256; ++n) {
    uint32_t c = n;
    for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    stbiw__crc_table[n] = c;
  }
  stbiw__crc_ready = 1;
}

static uint32_t stbiw__crc(const uint8_t *d, size_t n, uint32_t crc) {
  if (!stbiw__crc_ready) stbiw__crc_init();
  crc = crc ^ 0xFFFFFFFFu;
  for (size_t i = 0; i < n; ++i) crc = stbiw__crc_table[(crc ^ d[i]) & 0xFF] ^ (crc >> 8);
  return crc ^ 0xFFFFFFFFu;
}

static uint32_t stbiw__adler(const uint8_t *d, size_t n) {
  uint32_t a = 1, b = 0;
  for (size_t i = 0; i < n; ++i) {
    a = (a + d[i]) % 65521u;
    b = (b + a) % 65521u;
  }
  return (b << 16) | a;
}

static void stbiw__be32(uint8_t *p, uint32_t v) {
  p[0] = uint8_t(v >> 24);
  p[1] = uint8_t(v >> 16);
  p[2] = uint8_t(v >> 8);
  p[3] = uint8_t(v);
}

static int stbiw__chunk(FILE *f, const char type[4], const uint8_t *data, uint32_t len) {
  uint8_t hdr[8];
  stbiw__be32(hdr, len);
  memcpy(hdr + 4, type, 4);
  if (fwrite(hdr, 1, 8, f) != 8) return 0;
  if (len && fwrite(data, 1, len, f) != len) return 0;
  uint32_t crc = stbiw__crc((const uint8_t *)type, 4, 0);
  if (len) crc = stbiw__crc(data, len, crc);
  uint8_t tail[4];
  stbiw__be32(tail, crc);
  return fwrite(tail, 1, 4, f) == 4;
}

int stbi_write_png(char const *filename, int w, int h, int comp, const void *data, int stride_in_bytes) {
  if (!filename || w <= 0 || h <= 0 || !data) return 0;
  if (comp != 1 && comp != 2 && comp != 3 && comp != 4) return 0;

  const size_t row = size_t(w) * size_t(comp);
  const size_t stride = stride_in_bytes > 0 ? size_t(stride_in_bytes) : row;
  const uint8_t colour_type = comp == 1 ? 0 : comp == 2 ? 4 : comp == 3 ? 2 : 6;

  // Scanlines with filter 0 (none).
  const size_t raw_len = (row + 1) * size_t(h);
  uint8_t *raw = (uint8_t *)malloc(raw_len);
  if (!raw) return 0;
  for (int y = 0; y < h; ++y) {
    uint8_t *dst = raw + (size_t)y * (row + 1);
    dst[0] = 0;
    memcpy(dst + 1, (const uint8_t *)data + (size_t)y * stride, row);
  }

  // zlib stream: 0x78 0x01, then stored blocks of at most 65535 bytes, then Adler-32 of the raw scanlines.
  const size_t blocks = (raw_len + 65534) / 65535;
  const size_t idat_len = 2 + blocks * 5 + raw_len + 4;
  uint8_t *idat = (uint8_t *)malloc(idat_len);
  if (!idat) {
    free(raw);
    return 0;
  }
  size_t at = 0;
  idat[at++] = 0x78;
  idat[at++] = 0x01;
  for (size_t off = 0, i = 0; off < raw_len; off += 65535, ++i) {
    const size_t n = raw_len - off < 65535 ? raw_len - off : 65535;
    idat[at++] = uint8_t(off + n >= raw_len ? 1 : 0);  // BFINAL, BTYPE=00 (stored)
    idat[at++] = uint8_t(n & 0xFF);
    idat[at++] = uint8_t(n >> 8);
    idat[at++] = uint8_t(~n & 0xFF);
    idat[at++] = uint8_t((~n >> 8) & 0xFF);
    memcpy(idat + at, raw + off, n);
    at += n;
  }
  stbiw__be32(idat + at, stbiw__adler(raw, raw_len));
  at += 4;
  free(raw);

  FILE *f = fopen(filename, "wb");
  if (!f) {
    free(idat);
    return 0;
  }
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  uint8_t ihdr[13];
  stbiw__be32(ihdr, uint32_t(w));
  stbiw__be32(ihdr + 4, uint32_t(h));
  ihdr[8] = 8;             // bit depth
  ihdr[9] = colour_type;   // 0 grey, 2 RGB, 4 grey+alpha, 6 RGBA
  ihdr[10] = 0;            // deflate
  ihdr[11] = 0;            // adaptive filtering
  ihdr[12] = 0;            // no interlace

  int ok = fwrite(sig, 1, 8, f) == 8 && stbiw__chunk(f, "IHDR", ihdr, 13) &&
           stbiw__chunk(f, "IDAT", idat, uint32_t(at)) && stbiw__chunk(f, "IEND", nullptr, 0);
  free(idat);
  if (fclose(f) != 0) ok = 0;
  return ok;
}

#ifdef __cplusplus
}
#endif

#endif  // COGBOX_MAC_STB_IMAGE_WRITE_IMPL
#endif  // STB_IMAGE_WRITE_IMPLEMENTATION
