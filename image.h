#ifndef __IMAGE_H__
#define __IMAGE_H__

#include "sbuf.h"

// Kitty graphics protocol support for image attachments.
// Compiled only when build.zig is configured with -Dimage=true (USE_KITTY).
//
// Avatars are deliberately not rendered yet. When they are, the source URL is
// in the status JSON at "account/avatar"; rendering them in block layout above
// the status body needs no cursor math, just a smaller call to print_image().
void image_init(void);
void print_image(sbctx_t *, char *uri);

#endif
