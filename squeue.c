#include "squeue.h"
#include <stdlib.h>
#include <string.h>

static sbctx_t sbctx_data[QUEUE_SIZE];
static int sbctx_head;
static int sbctx_num;
static pthread_mutex_t sbctx_mutex;

static char *raw_data[QUEUE_SIZE];
static ssize_t raw_sizes[QUEUE_SIZE];
static int raw_head;
static int raw_num;
static pthread_mutex_t raw_mutex;

void squeue_init(void)
{
	pthread_mutex_init(&sbctx_mutex, NULL);
	sbctx_head = 0;
	sbctx_num = 0;
	
	pthread_mutex_init(&raw_mutex, NULL);
	raw_head = 0;
	raw_num = 0;
}

int squeue_enqueue(sbctx_t sb)
{
	int ret = 0;
	pthread_mutex_lock(&sbctx_mutex);

	if (sbctx_num < QUEUE_SIZE) {
		sbctx_data[(sbctx_head + sbctx_num) % QUEUE_SIZE] = sb;
		sbctx_num++;
		ret = 0;
	} else {
		ret = 1;
	}

	pthread_mutex_unlock(&sbctx_mutex);
	return ret;
}

int squeue_dequeue(sbctx_t *sb)
{
	int ret = 0;
	pthread_mutex_lock(&sbctx_mutex);

	if (sbctx_num > 0) {
		*sb = sbctx_data[sbctx_head];
		sbctx_head = (sbctx_head + 1) % QUEUE_SIZE;
		sbctx_num--;
		ret = 0;
	} else {
		ret = 1;
	}

	pthread_mutex_unlock(&sbctx_mutex);
	return ret;
}

int squeue_enqueue_raw(char *buf, ssize_t size)
{
	int ret = 0;
	pthread_mutex_lock(&raw_mutex);

	if (raw_num < QUEUE_SIZE) {
		char *copy = (char*)malloc(size);
		if (copy) {
			memcpy(copy, buf, size);
			raw_data[(raw_head + raw_num) % QUEUE_SIZE] = copy;
			raw_sizes[(raw_head + raw_num) % QUEUE_SIZE] = size;
		}
		raw_num++;
		ret = 0;
	} else {
		ret = 1;
	}

	pthread_mutex_unlock(&raw_mutex);
	return ret;
}

int squeue_dequeue_raw(queue_item_t *item)
{
	int ret = 0;
	pthread_mutex_lock(&raw_mutex);

	if (raw_num > 0) {
		item->data = raw_data[raw_head];
		item->size = raw_sizes[raw_head];
		raw_head = (raw_head + 1) % QUEUE_SIZE;
		raw_num--;
		ret = 0;
	} else {
		ret = 1;
	}

	pthread_mutex_unlock(&raw_mutex);
	return ret;
}