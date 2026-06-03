#ifndef __SQUEUE_H__
#define __SQUEUE_H__

#include <pthread.h>
#include <sys/types.h>

#define QUEUE_SIZE 512

// Generic byte buffer for storing flattened data
typedef struct {
	char *data;
	ssize_t size;
} queue_item_t;

void squeue_init(void);
int squeue_enqueue_raw(char *buf, ssize_t size);
int squeue_dequeue_raw(queue_item_t *item);

#endif