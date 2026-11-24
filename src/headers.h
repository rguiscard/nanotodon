// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

#include <stddef.h> // size_t

// Startup, called from src/main.zig: the locale and the small amount of state
// C still keeps. Must run before the threads start.
void nanotodon_runtime(void);

// The streaming loop, the notification formatting, the status rendering and the
// image attachments are all Zig now (src/stream.zig, src/notify.zig,
// src/status.zig, src/image.zig); nothing here decodes stream JSON any more.

#define NANOTODON_TIMELINE_HOME   0
#define NANOTODON_TIMELINE_LOCAL  1
#define NANOTODON_TIMELINE_PUBLIC 2

// ---- image attachments (-DUSE_KITTY) ----

// Implemented in C (image.c): stb_image decoding only. Returns RGBA (4 bytes
// per pixel) or NULL, writing the size to `w`/`h`. src/image.zig owns
// everything else; the result is released with stb_image_free().
unsigned char *nanotodon_decode_image(const unsigned char *data, int len, int *w, int *h);
void nanotodon_stb_image_free(void *pixels);
