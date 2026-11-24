// Image decoding for attachments.
//
// This file is only stb_image now: fetching, the on-disk cache, cell sizing and
// the Kitty escape stream live in src/image.zig, and the pixel encoding in
// src/kitty.zig. Decoding stays here because stb_image is a single-header C
// library; wrapping one function is far less work than translating it.
//
// Compiled only with -DUSE_KITTY (build.zig: -Dimage=true).

#include "src/headers.h"

#include <stdint.h>
#include <stdlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_BMP
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#include "stb_image.h"

// Decode `data` as an image and return it as RGBA, 4 bytes per pixel, or NULL.
// `w`/`h` receive the dimensions. The caller owns the result and releases it
// with stb_image_free().
unsigned char *nanotodon_decode_image(const unsigned char *data, int len, int *w, int *h)
{
	return stbi_load_from_memory(data, len, w, h, NULL, 4);
}

void nanotodon_stb_image_free(void *pixels)
{
	stbi_image_free(pixels);
}
