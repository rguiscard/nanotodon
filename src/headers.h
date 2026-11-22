// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

// Startup phases, called from src/main.zig in this order:
//   prepare_paths -> authenticate -> runtime
// The order matters, so they are separate calls rather than one entry point.

// Resolves config.root_dir/cache_dir, creates the directories and computes the
// token/domain paths. Touches neither the network nor stdin, so it can run
// before the socket is bound.
void nanotodon_prepare_paths(void);

// Loads the access token, or runs the interactive OAuth registration (may block
// on stdin). Also initialises libcurl.
void nanotodon_authenticate(void);

// Locale, output queue and (if enabled) Sixel. Must run before the threads start.
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
// statics that stop changing once nanotodon_authenticate() has returned, so they
// are safe to read from the connection-handler threads.
const char *nanotodon_domain(void);
const char *nanotodon_auth_header(void);

// Command line options. Parsed in Zig (src/cli.zig), then handed over with a
// single call to nanotodon_apply_cli_options() before nanotodon_prepare_paths() runs.
typedef struct nanotodon_cli_options {
	int mono;             // -mono
	int unlock;           // -unlock
	int no_emoji;         // -noemoji
	const char *profile;  // -profile <name>, NULL when not given
	int limit_timeline;   // -tllimit <num>, < 0 keeps the C default
	int timeline;         // NANOTODON_TIMELINE_*
} nanotodon_cli_options;

void nanotodon_apply_cli_options(const nanotodon_cli_options *opts);
