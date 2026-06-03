#ifndef __SQUEUE_H__
#define __SQUEUE_H__

#include <pthread.h>
#include <sys/types.h>
#include "sbuf.h"

#define QUEUE_SIZE 512

// Generic byte buffer for storing flattened data
typedef struct {
	char *data;
	ssize_t size;
} queue_item_t;

// Original sbctx_t-based functions for backward compatibility
void squeue_init(void);
int squeue_enqueue(sbctx_t sb);
int squeue_dequeue(sbctx_t *sb);

// Raw buffer enqueue (for BMessage flattened data in C++)
int squeue_enqueue_raw(char *buf, ssize_t size);
int squeue_dequeue_raw(queue_item_t *item);

#endif