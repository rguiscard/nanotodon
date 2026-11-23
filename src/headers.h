// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

// Startup phases, called from src/main.zig in this order:
//   set_cache_dir -> set_credentials -> runtime
// Everything else (paths, credentials, first-run registration) is Zig now;
// src/image.c is the only C code that still needs a path.

// Hands the Zig-computed image cache directory to C.
void nanotodon_set_cache_dir(const char *dir);

// Sets the curl header value ("Authorization: Bearer ...") and the instance
// hostname.
void nanotodon_set_credentials(const char *auth_header, const char *domain);

// Locale, output queue and (if built with -Dimage) the image cache path.
// Must run before the threads start.
void nanotodon_runtime(void);

// Runs the blocking streaming loop (curl SSE). Blocking, so src/main.zig starts
// it on its own thread; it never returns unless the process dies.
void nanotodon_stream_loop(void);

// Hook called by the Zig render loop (src/loop.zig).
void nanotodon_pump_output(void);

#define NANOTODON_TIMELINE_HOME   0
#define NANOTODON_TIMELINE_LOCAL  1
#define NANOTODON_TIMELINE_PUBLIC 2

// ---- image attachments (-DUSE_KITTY) ----

// Implemented in C (sbuf.c): lets Zig append to an sbctx without exposing the
// struct layout.
void nanotodon_sbuf_put(void *sbctx, const void *data, int len);

// Implemented in Zig (src/kitty.zig): encodes decoded RGBA pixels as Kitty
// graphics and appends the escape stream to `sbctx`. Called from image.c.
void nanotodon_kitty_emit(void *sbctx, const void *rgba, int w, int h);

// Read-only accessors for the Zig poster (src/poster.zig). Both point at C
// statics that stop changing once nanotodon_set_credentials() has returned, so they
// are safe to read from the connection-handler threads.
const char *nanotodon_domain(void);
const char *nanotodon_auth_header(void);

// CLI options are parsed in Zig (src/cli.zig) and handed over with a single
// call to nanotodon_apply_cli_options().
typedef struct nanotodon_cli_options {
	int mono;             // -mono
	int unlock;           // -unlock
	int no_emoji;         // -noemoji
	int limit_timeline;   // -tllimit <num>, < 0 keeps the C default
	int timeline;         // NANOTODON_TIMELINE_*
} nanotodon_cli_options;

void nanotodon_apply_cli_options(const nanotodon_cli_options *opts);
