#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "nanotodon.h"
#include "utils.h"

// curlのコールバック
size_t buffer_writer(char *ptr, size_t size, size_t nmemb, void *stream) {
	struct rawBuffer *buf = (struct rawBuffer *)stream;
	int block = size * nmemb;
	if (!buf) {
		return block;
	}

	if (!buf->data) {
		buf->data = malloc(block);
	}
	else {
		buf->data = realloc(buf->data, buf->data_size + block);
	}

	if (buf->data) {
		memcpy(buf->data + buf->data_size, ptr, block);
		buf->data_size += block;
	}

	return block;
}
