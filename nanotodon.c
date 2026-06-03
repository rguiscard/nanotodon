#include <curl/curl.h>
#include <stdlib.h>
#include <stdint.h>
#include <strings.h>
#include <string.h> // memmove
#include <time.h>   // strptime, strptime, timegm, localtime
#include <ctype.h>  // isspace
#include <locale.h> // setlocale
#include <sys/time.h>
#include <pthread.h>

#define SJSON_IMPLEMENT
#include "sjson.h"

#include "nanotodon.h"
#include "config.h"
#include "messages.h"
#include "sbuf.h"
#include "squeue.h"
#include "utils.h"
#include "sixel.h"

char *streaming_json = NULL;

#define URI_STREAM "api/v1/streaming/"
#define URI_TIMELINE "api/v1/timelines/"

const char *selected_stream = "user";
const char *selected_timeline = "home";
char append_timeline[64];
int limit_timeline = 20;

#define CURL_USERAGENT "curl/" LIBCURL_VERSION


int prompt_notify = 0;
pthread_mutex_t prompt_mutex;

// Pointer to the function that receives streaming data
static void (*streaming_received_handler)(void);

// Pointer to the function that processes received streaming data
static void (*stream_event_handler)(struct sjson_node *);

// Stream event handlers - implemented in Haikutodon.cpp
void stream_event_update(struct sjson_node *);
void stream_event_notify(struct sjson_node *);

// Register the client with the instance
void do_create_client(char *, char *);

// Receive timeline
void get_timeline(void);

// OAuth processing using authorization code
void do_oauth(char *, char *, char *);

// Post a toot
void do_toot(char *);

// Access token string
char access_token[256];

// Domain string
char domain_string[256];

// Config file path structure
struct nanotodon_config config;

int monoflag = 0;
int hidlckflag = 1;
int noemojiflag = 0;

// Streaming receive function called from curl
static size_t streaming_callback(void* ptr, size_t size, size_t nmemb, void* data) {
	if (size * nmemb == 0)
		return 0;

	char **json = ((char **)data);

	size_t realsize = size * nmemb;

	size_t length = realsize + 1;
	char *str = *json;
	str = realloc(str, (str ? strlen(str) : 0) + length);
	if(*((char **)data) == NULL) strcpy(str, "");

	*json = str;

	if (str != NULL) {
		strncat(str, ptr, realsize);
		// If a newline arrives, it indicates end of data (but may not be contained in one receive)
		if(str[strlen(str)-1] == 0x0a) {
			if(*str == ':') {
				// Only ':' is for keep-alive
				free(str);
				*json = NULL;
			} else {
				streaming_received_handler();
			}
		}
	}

	return realsize;
}

// Streaming receive handler (called when streaming data arrives)
static void streaming_received(void)
{
	// イベント取得
	if(strncmp(streaming_json, "event", 5) == 0) {
		char *type = strdup(streaming_json + 7);
		if(strncmp(type, "update", 6) == 0) stream_event_handler = stream_event_update;
		else if(strncmp(type, "notification", 12) == 0) stream_event_handler = stream_event_notify;
		else stream_event_handler = NULL;

		char *top = type;
		while(*type != '\n') type++;
		type++;

		// 後ろにJSONが引っ付いていればJSONバッファへ
		if(*type != 0) {
			free(streaming_json);
			streaming_json = strdup(type);
		}
		free(top);
	}

	// JSON受信
	if(strncmp(streaming_json, "data", 4) == 0) {
		if(stream_event_handler) {
			sjson_context* ctx = sjson_create_context(0, 0, NULL);
			struct sjson_node *jobj_from_string = sjson_decode(ctx, streaming_json + 6);

			stream_event_handler(jobj_from_string);

			sjson_destroy_context(ctx);
			stream_event_handler = NULL;
		}
	}

	free(streaming_json);
	streaming_json = NULL;
}

// ストリーミング受信スレッド
void *stream_thread_func(void *param)
{
	get_timeline();

	CURLcode ret;
	CURL *hnd;
	struct curl_slist *slist1;
	char errbuf[CURL_ERROR_SIZE], *uri;

	slist1 = NULL;
	slist1 = curl_slist_append(slist1, access_token);
	memset(errbuf, 0, sizeof errbuf);

	char *uri_stream = malloc(strlen(URI_STREAM) + strlen(selected_stream) + 1);

	strcpy(uri_stream, URI_STREAM);
	strcat(uri_stream, selected_stream);

	uri = create_uri_string(uri_stream);

	hnd = curl_easy_init();
	curl_easy_setopt(hnd, CURLOPT_URL, uri);
	curl_easy_setopt(hnd, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(hnd, CURLOPT_USERAGENT, CURL_USERAGENT);
	curl_easy_setopt(hnd, CURLOPT_HTTPHEADER, slist1);
	curl_easy_setopt(hnd, CURLOPT_MAXREDIRS, 50L);
	curl_easy_setopt(hnd, CURLOPT_CUSTOMREQUEST, "GET");
	curl_easy_setopt(hnd, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(hnd, CURLOPT_TIMEOUT, 0);
	curl_easy_setopt(hnd, CURLOPT_WRITEDATA, (void *)&streaming_json);
	curl_easy_setopt(hnd, CURLOPT_WRITEFUNCTION, streaming_callback);
	curl_easy_setopt(hnd, CURLOPT_ERRORBUFFER, errbuf);

	streaming_received_handler = streaming_received;
	stream_event_handler = NULL;

	ret = curl_easy_perform(hnd);
	if(ret != CURLE_OK) curl_fatal(ret, errbuf);

	curl_easy_cleanup(hnd);
	hnd = NULL;
	free(uri_stream);
	free(uri);
	curl_slist_free_all(slist1);
	slist1 = NULL;

	return NULL;
}

void *prompt_thread_func(void *param)
{
	while(1) {
		if(prompt_notify == 0) {
			int c = fgetc(stdin);

			if(c == '\n') {
				prompt_notify = 1;
			}
		} else {
			const struct timespec req = {0, 100 * 1000000};
			nanosleep(&req, NULL);
		}
	}

	return NULL;
}

// インスタンスにクライアントを登録する
void do_create_client(char *domain, char *dot_ckcs)
{
	CURLcode ret;
	CURL *hnd;
	curl_mime *mime;
	curl_mimepart *part;
	char errbuf[CURL_ERROR_SIZE];

	char json_name[256], *uri;

	strcpy(json_name, dot_ckcs);

	uri = create_uri_string("api/v1/apps");

	// クライアントキーファイルをオープン
	FILE *f = fopen(json_name, "wb");

	memset(errbuf, 0, sizeof errbuf);

	hnd = curl_easy_init();
	mime = curl_mime_init(hnd);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "client_name");
	curl_mime_data(part, "nanotodon", CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "redirect_uris");
	curl_mime_data(part, "urn:ietf:wg:oauth:2.0:oob", CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "scopes");
	curl_mime_data(part, "read write follow", CURL_ZERO_TERMINATED);
	curl_easy_setopt(hnd, CURLOPT_URL, uri);
	curl_easy_setopt(hnd, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(hnd, CURLOPT_MIMEPOST, mime);
	curl_easy_setopt(hnd, CURLOPT_USERAGENT, CURL_USERAGENT);
	curl_easy_setopt(hnd, CURLOPT_MAXREDIRS, 50L);
	curl_easy_setopt(hnd, CURLOPT_CUSTOMREQUEST, "POST");
	curl_easy_setopt(hnd, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(hnd, CURLOPT_WRITEDATA, f);	// データの保存先ファイルポインタを指定
	curl_easy_setopt(hnd, CURLOPT_ERRORBUFFER, errbuf);

	ret = curl_easy_perform(hnd);
	if(ret != CURLE_OK) curl_fatal(ret, errbuf);

	fclose(f);

	curl_mime_free(mime);
	mime = NULL;
	curl_easy_cleanup(hnd);
	hnd = NULL;
	free(uri);
}

// 承認コードを使ったOAuth処理
void do_oauth(char *code, char *ck, char *cs)
{
	char fields[512];
	sprintf(fields, "client_id=%s&client_secret=%s&grant_type=authorization_code&code=%s&scope=read%%20write%%20follow", ck, cs, code);

	// トークンファイルをオープン
	FILE *f = fopen(config.dot_token, "wb");

	CURLcode ret;
	CURL *hnd;
	curl_mime *mime;
	curl_mimepart *part;
	char errbuf[CURL_ERROR_SIZE], *uri;

	memset(errbuf, 0, sizeof errbuf);

	uri = create_uri_string("oauth/token");

	hnd = curl_easy_init();
	mime = curl_mime_init(hnd);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "grant_type");
	curl_mime_data(part, "authorization_code", CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "redirect_uri");
	curl_mime_data(part, "urn:ietf:wg:oauth:2.0:oob", CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "client_id");
	curl_mime_data(part, ck, CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "client_secret");
	curl_mime_data(part, cs, CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "code");
	curl_mime_data(part, code, CURL_ZERO_TERMINATED);
	curl_easy_setopt(hnd, CURLOPT_URL, uri);
	curl_easy_setopt(hnd, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(hnd, CURLOPT_MIMEPOST, mime);
	curl_easy_setopt(hnd, CURLOPT_USERAGENT, CURL_USERAGENT);
	curl_easy_setopt(hnd, CURLOPT_MAXREDIRS, 50L);
	curl_easy_setopt(hnd, CURLOPT_CUSTOMREQUEST, "POST");
	curl_easy_setopt(hnd, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(hnd, CURLOPT_WRITEDATA, f);	// データの保存先ファイルポインタを指定
	curl_easy_setopt(hnd, CURLOPT_ERRORBUFFER, errbuf);

	ret = curl_easy_perform(hnd);
	if(ret != CURLE_OK) curl_fatal(ret, errbuf);

	fclose(f);

	curl_mime_free(mime);
	mime = NULL;
	curl_easy_cleanup(hnd);
	hnd = NULL;
	free(uri);
}

// Tootを行う
void do_toot(char *s)
{
	CURLcode ret;
	CURL *hnd;
	curl_mime *mime;
	curl_mimepart *part;
	struct curl_slist *slist1;
	char errbuf[CURL_ERROR_SIZE], *uri;

	int is_locked = 0;
	int is_unlisted = 0;

	if(*s == '/') {
		if(s[1] != 0) {
			if(s[1] == '/') {
				s++;
			} else if(strncmp(s+1,"private",7) == 0) {
				is_locked = 1;
				s += 1+7;
			} else if(strncmp(s+1,"unlisted",8) == 0) {
				is_unlisted = 1;
				s += 1+8;
			}
		}
	}

	FILE *f = fopen("/dev/null", "wb");

	uri = create_uri_string("api/v1/statuses");

	memset(errbuf, 0, sizeof errbuf);
	slist1 = NULL;
	slist1 = curl_slist_append(slist1, access_token);

	hnd = curl_easy_init();
	mime = curl_mime_init(hnd);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "status");
	curl_mime_data(part, s, CURL_ZERO_TERMINATED);
	part = curl_mime_addpart(mime);
	curl_mime_name(part, "visibility");
	curl_mime_data(part, is_locked ? "private" : (is_unlisted ? "unlisted" : "public"), CURL_ZERO_TERMINATED);
	curl_easy_setopt(hnd, CURLOPT_URL, uri);
	curl_easy_setopt(hnd, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(hnd, CURLOPT_MIMEPOST, mime);
	curl_easy_setopt(hnd, CURLOPT_USERAGENT, CURL_USERAGENT);
	curl_easy_setopt(hnd, CURLOPT_HTTPHEADER, slist1);
	curl_easy_setopt(hnd, CURLOPT_MAXREDIRS, 50L);
	curl_easy_setopt(hnd, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(hnd, CURLOPT_WRITEDATA, f);
	curl_easy_setopt(hnd, CURLOPT_ERRORBUFFER, errbuf);

	ret = curl_easy_perform(hnd);
	if(ret != CURLE_OK) curl_fatal(ret, errbuf);

	fclose(f);

	curl_mime_free(mime);
	mime = NULL;
	curl_easy_cleanup(hnd);
	hnd = NULL;
	free(uri);
	curl_slist_free_all(slist1);
	slist1 = NULL;
}

// curlから呼び出されるHTL受信関数
static size_t htl_callback(void* ptr, size_t size, size_t nmemb, void* data) {
	if (size * nmemb == 0)
		return 0;

	char **json = ((char **)data);

	size_t realsize = size * nmemb;

	size_t length = realsize + 1;
	char *str = *json;
	str = realloc(str, (str ? strlen(str) : 0) + length);
	if(*((char **)data) == NULL) strcpy(str, "");

	*json = str;

	if (str != NULL) {
		strncat(str, ptr, realsize);
	}

	return realsize;
}

// Timelineの受信
void get_timeline(void)
{
	CURLcode ret;
	CURL *hnd;
	struct curl_slist *slist1;
	char errbuf[CURL_ERROR_SIZE], *uri;

	slist1 = NULL;
	slist1 = curl_slist_append(slist1, access_token);
	memset(errbuf, 0, sizeof errbuf);

	char *uri_timeline = malloc(strlen(URI_TIMELINE) + strlen(selected_timeline) + (1 + 5 + 1 + 2 /*? limit = xx*/) + 1);

	sprintf(append_timeline, "?limit=%d", limit_timeline);

	strcpy(uri_timeline, URI_TIMELINE);
	strcat(uri_timeline, selected_timeline);
	strcat(uri_timeline, append_timeline);

	uri = create_uri_string(uri_timeline);

	char *json = NULL;

	hnd = curl_easy_init();
	curl_easy_setopt(hnd, CURLOPT_URL, uri);
	curl_easy_setopt(hnd, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(hnd, CURLOPT_USERAGENT, CURL_USERAGENT);
	curl_easy_setopt(hnd, CURLOPT_HTTPHEADER, slist1);
	curl_easy_setopt(hnd, CURLOPT_MAXREDIRS, 50L);
	curl_easy_setopt(hnd, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(hnd, CURLOPT_WRITEDATA, (void *)&json);
	curl_easy_setopt(hnd, CURLOPT_WRITEFUNCTION, htl_callback);
	curl_easy_setopt(hnd, CURLOPT_ERRORBUFFER, errbuf);

	ret = curl_easy_perform(hnd);
	if(ret != CURLE_OK) curl_fatal(ret, errbuf);


	sjson_context* ctx = sjson_create_context(0, 0, NULL);
	struct sjson_node *jobj_from_string = sjson_decode(ctx, json);
	sjson_tag type;

	type = jobj_from_string->tag;

	if(type == SJSON_ARRAY) {
		for (int i = sjson_child_count(jobj_from_string) - 1; i >= 0; i--) {
			struct sjson_node *obj = sjson_find_element(jobj_from_string, i);

			stream_event_update(obj);
		}
	}

	sjson_destroy_context(ctx);

	curl_easy_cleanup(hnd);
	hnd = NULL;
	free(uri_timeline);
	free(uri);
	curl_slist_free_all(slist1);
	slist1 = NULL;
}