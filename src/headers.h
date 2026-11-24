// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

#include <stddef.h> // size_t

// Startup phases, called from src/main.zig in this order:
//   set_cache_dir -> runtime
// Everything else (paths, credentials, first-run registration) is Zig now;
// src/image.c is the only C code that still needs a path.

// Hands the Zig-computed image cache directory to C.
void nanotodon_set_cache_dir(const char *dir);

// Locale, output queue and (if built with -Dimage) the image cache path.
// Must run before the threads start.
void nanotodon_runtime(void);

// The streaming loop, the notification formatting and the status rendering are
// all Zig now (src/stream.zig, src/notify.zig, src/status.zig); nothing here
// decodes stream JSON any more.

#define NANOTODON_TIMELINE_HOME   0
#define NANOTODON_TIMELINE_LOCAL  1
#define NANOTODON_TIMELINE_PUBLIC 2

// ---- image attachments (-DUSE_KITTY) ----

// Implemented in C (sbuf.c): lets Zig append to an sbctx without exposing the
// struct layout.
void nanotodon_sbuf_put(void *sbctx, const void *data, int len);

// Implemented in Zig (src/main.zig): writes to stdout under the one output
// mutex (see src/out.zig).
void nanotodon_out_write_zig(const void *data, size_t len);

// Implemented in C (image.c): fetches/decodes one attachment URL and writes the
// Kitty escape sequence. Only present with -Dimage=true.
void nanotodon_print_image_zig(const char *uri);

// Implemented in C (sbuf.c): hands finished bytes to the Zig output path.
// Used by src/image.c, which builds its Kitty escape sequence in an sbctx_t.
void nanotodon_out_write(const void *data, int len);

// Implemented in Zig (src/kitty.zig): encodes decoded RGBA pixels as Kitty
// graphics and appends the escape stream to `sbctx`. Called from image.c.
void nanotodon_kitty_emit(void *sbctx, const void *rgba, int w, int h);
