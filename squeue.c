#include "squeue.h"
#include <stdlib.h>
#include <string.h>

static char *raw_data[QUEUE_SIZE];
static ssize_t raw_sizes[QUEUE_SIZE];
static int raw_head;
static int raw_num;
static pthread_mutex_t raw_mutex;

void squeue_init(void)
{
	pthread_mutex_init(&raw_mutex, NULL);
	raw_head = 0;
	raw_num = 0;
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