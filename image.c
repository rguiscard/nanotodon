// Inline image attachments using the Kitty graphics protocol.
//
// This file only fetches the media, decodes it with stb_image and caches the
// encoded result. The protocol side — cell sizing, RGBA -> RGB, base64 chunking
// and the escape stream — lives in src/kitty.zig and is reached through
// nanotodon_kitty_emit().
//
// Compiled only with -DUSE_KITTY (build.zig: -Dimage=true). Avatars are not
// rendered, and sensitive attachments are replaced by a placeholder before this
// file is ever called.

#include "nanotodon.h"
#include "image.h"
#include "utils.h"
#include "src/headers.h"

#include <curl/curl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_BMP
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#include "stb_image.h"

// Layout and encoding live in src/kitty.zig; this file owns fetching, decoding
// and the on-disk cache.

static char cpath_buffer[512];
static char *cpath_ptr;

static void generate_hash(const char *, char *);

void image_init(void)
{
	strcpy(cpath_buffer, nanotodon_cache_dir());
	cpath_ptr = cpath_buffer + strlen(cpath_buffer);
}

// FNV-1a over the URI. The cache key only has to be stable on one machine, so a
// short table-free hash is enough (and is why old .six cache files never
// collide with these).
static void generate_hash(const char *uri, char *out)
{
	uint64_t h = 0xcbf29ce484222325ULL;

	for(const unsigned char *p = (const unsigned char *)uri; *p; p++) {
		h ^= *p;
		h *= 0x100000001b3ULL;
	}

	for(int i = 0; i < 16; i++) {
		out[i] = "0123456789abcdef"[(h >> (60 - i * 4)) & 15];
	}
	out[16] = 0;
}

void print_image(sbctx_t *sbctx, char *uri)
{
	char hash[24] = {0};
	char cpath[64];

	generate_hash(uri, hash);
	snprintf(cpath, sizeof cpath, "/%s.kit", hash);

	if(strlen(nanotodon_cache_dir()) + strlen(cpath) + 1 > sizeof cpath_buffer) return;
	strcpy(cpath_ptr, cpath);

	FILE *cfp = fopen(cpath_buffer, "rb");
	if(cfp) {
		int len = 0;
		if(fread(&len, sizeof len, 1, cfp) == 1 && len > 0) {
			void *p = malloc((size_t)len);
			if(p) {
				if(fread(p, (size_t)len, 1, cfp) == 1) nputbuf(sbctx, p, len);
				free(p);
			}
		}
		fclose(cfp);
		return;
	}

	struct rawBuffer *buf = (struct rawBuffer *)malloc(sizeof(struct rawBuffer));
	if(!buf) return;
	buf->data = NULL;
	buf->data_size = 0;

	CURL *curl = curl_easy_init();
	if(!curl) {
		free(buf);
		return;
	}
	curl_easy_setopt(curl, CURLOPT_URL, uri);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, buf);
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, buffer_writer);
	curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
	const CURLcode ret = curl_easy_perform(curl);
	curl_easy_cleanup(curl);

	if(ret == CURLE_OK && buf->data && buf->data_size > 0) {
		int iw = 0, ih = 0, ic = 0;
		stbi_uc *pix = stbi_load_from_memory(
			(const stbi_uc *)buf->data, buf->data_size, &iw, &ih, &ic, 4);

		if(pix && iw > 0 && ih > 0) {
			sbctx_t sb2;
			ninitbuf(&sb2);
			nanotodon_kitty_emit(&sb2, pix, iw, ih);
			nflushcache(&sb2);

			nputbuf(sbctx, sb2.buf, sb2.bufptr);

			FILE *fp = fopen(cpath_buffer, "wb");
			if(fp) {
				int len = sb2.bufptr;
				fwrite(&len, sizeof len, 1, fp);
				fwrite(sb2.buf, (size_t)len, 1, fp);
				fclose(fp);
			}

			free(sb2.buf);
		}

		if(pix) stbi_image_free(pix);
	}

	free(buf->data);
	free(buf);
}
