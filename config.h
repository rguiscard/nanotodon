#ifndef NANOTODON_CONFIG_H
#define NANOTODON_CONFIG_H

#include <stdlib.h>

// Paths are computed in Zig (src/config.zig) and pushed in through
// nanotodon_set_paths(); C only ever uses them.
struct nanotodon_config {
	char root_dir[256];
	char dot_token[256];
	char dot_domain[256];

	char cache_dir[256];
};

// Builds <root_dir>/app_token/<domain> and creates the app_token directory.
// Used only by the first-run registration in nanotodon.c.
int nano_config_app_token_filename(struct nanotodon_config *, const char *, char *, size_t);

#endif
