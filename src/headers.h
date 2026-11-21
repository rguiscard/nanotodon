// Declarations shared between the C implementation and the Zig front end.
// This file is the only translate-c input (see build.zig), so it has to stay
// self-contained: plain C declarations, no #include of project headers.

int c_main(void);

#define NANOTODON_TIMELINE_HOME   0
#define NANOTODON_TIMELINE_LOCAL  1
#define NANOTODON_TIMELINE_PUBLIC 2

// Command line options. Parsed in Zig (src/cli.zig), then handed over with a
// single call to nanotodon_apply_cli_options() before c_main() runs.
typedef struct nanotodon_cli_options {
	int mono;             // -mono
	int unlock;           // -unlock
	int no_emoji;         // -noemoji
	const char *profile;  // -profile <name>, NULL when not given
	int limit_timeline;   // -tllimit <num>, < 0 keeps the C default
	int timeline;         // NANOTODON_TIMELINE_*
} nanotodon_cli_options;

void nanotodon_apply_cli_options(const nanotodon_cli_options *opts);
