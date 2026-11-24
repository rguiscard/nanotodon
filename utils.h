#ifndef __UTILS_H__
#define __UTILS_H__

#include <curl/curl.h>
#include <stdint.h>
#include "sjson.h"

int ustrwidth(const char *);

void curl_fatal(CURLcode, const char *);

int read_json_fom_path(struct sjson_node *, const char *, struct sjson_node **);


struct rawBuffer {
	unsigned char *data;
	int data_size;
};

size_t buffer_writer(char *, size_t, size_t, void *);

#endif
