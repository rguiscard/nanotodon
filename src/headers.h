// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

int nanotodon_start(void);

// Creates the config directories (root_dir/cache_dir) without computing the
// token/domain paths, so main() can call it before binding the socket.
// Idempotent; may exit on a fatal setup error, like nano_config_init().
void nanotodon_init_dirs(void);

// Hooks called by the Zig event loop (src/loop.zig).
void nanotodon_pump_output(void);
int  nanotodon_prompt_pending(void);
int  nanotodon_read_toot(char *buf, int size);
void nanotodon_post_status(const char *status);
void nanotodon_prompt_clear(void);

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
// single call to nanotodon_apply_cli_options() before nanotodon_start() runs.
typedef struct nanotodon_cli_options {
	int mono;             // -mono
	int unlock;           // -unlock
	int no_emoji;         // -noemoji
	const char *profile;  // -profile <name>, NULL when not given
	int limit_timeline;   // -tllimit <num>, < 0 keeps the C default
	int timeline;         // NANOTODON_TIMELINE_*
} nanotodon_cli_options;

void nanotodon_apply_cli_options(const nanotodon_cli_options *opts);
