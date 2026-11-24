#ifndef __UTILS_H__
#define __UTILS_H__

#include <curl/curl.h>
#include <stdint.h>

struct rawBuffer {
	unsigned char *data;
	int data_size;
};

size_t buffer_writer(char *, size_t, size_t, void *);

#endif
