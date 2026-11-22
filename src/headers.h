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

#define NANOTODON_VISIBILITY_PUBLIC   0
#define NANOTODON_VISIBILITY_UNLISTED 1
#define NANOTODON_VISIBILITY_PRIVATE  2
#define NANOTODON_VISIBILITY_DIRECT   3

// Posts a status with the given NANOTODON_VISIBILITY_* value.
// Returns 0 on success, -1 on failure with a message in errbuf.
// Never exits the process (unlike curl_fatal).
// Lengths are `int` because the JSON protocol caps a request line at 64 KiB.
int nanotodon_post_toot(const char *status, int status_len, int visibility, char *errbuf, int errlen);

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
