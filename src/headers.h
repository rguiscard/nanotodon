// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.
//
// The only C left is stb_image decoding (image.c), used when built with
// -Dimage. Startup, the streaming loop, notifications, status rendering and the
// Kitty escape stream are all Zig (src/*.zig).

#include <stddef.h> // size_t

#define NANOTODON_TIMELINE_HOME   0
#define NANOTODON_TIMELINE_LOCAL  1
#define NANOTODON_TIMELINE_PUBLIC 2

// ---- image attachments (-DUSE_KITTY) ----

// Implemented in C (image.c): stb_image decoding only. Returns RGBA (4 bytes
// per pixel) or NULL, writing the size to `w`/`h`. src/image.zig owns
// everything else; the result is released with stb_image_free().
unsigned char *nanotodon_decode_image(const unsigned char *data, int len, int *w, int *h);
void nanotodon_stb_image_free(void *pixels);
