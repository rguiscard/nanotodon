#ifndef __IMAGE_H__
#define __IMAGE_H__

// Image attachments: only decoding is still C (stb_image).
//
// Everything else — fetching the URL, the on-disk cache, the Kitty graphics
// escape stream, and placing it in the output — is src/image.zig. Compiled only
// when build.zig is configured with -Dimage=true (USE_KITTY).
//
// Avatars are deliberately not rendered yet. When they are, the source URL is
// in the status JSON at "account/avatar"; rendering them above the status body
// needs no placement work, just a call to src/image.zig's escape().

// Returns RGBA (4 bytes per pixel) or NULL, writing the size to `w`/`h`.
unsigned char *nanotodon_decode_image(const unsigned char *data, int len, int *w, int *h);
void nanotodon_stb_image_free(void *pixels);

#endif
