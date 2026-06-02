#ifndef __HAIKUTODON_H__
#define __HAIKUTODON_H__

#ifdef __cplusplus
extern "C" {
#endif

#include "nanotodon.h"
#include "config.h"
#include <stdint.h>
#include "sjson.h"
#include "sbuf.h"
#include "squeue.h"
#include "messages.h"
#include <locale.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "utils.h"

// Expose variables from nanotodon.c that are needed by main
extern int hidlckflag;
extern int noemojiflag;
extern char access_token[256];
extern int prompt_notify;
extern const char *selected_stream;
extern const char *selected_timeline;
extern char append_timeline[64];
extern int limit_timeline;
extern pthread_mutex_t prompt_mutex;

// Expose functions from nanotodon.c
void *stream_thread_func(void *param);
void *prompt_thread_func(void *param);
void get_timeline(void);
void do_toot(char *s);
void do_create_client(char *domain, char *dot_ckcs);
void do_oauth(char *code, char *ck, char *cs);

#ifdef __cplusplus
}
#endif

#endif // __HAIKUTODON_H__
