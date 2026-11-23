#ifndef __NANOTODON_H__
#define __NANOTODON_H__

extern int monoflag;
extern char domain_string[256];
// Image cache directory, set once from Zig (src/config.zig) through
// nanotodon_set_cache_dir(). Used by src/image.c.
const char *nanotodon_cache_dir(void);

#endif
