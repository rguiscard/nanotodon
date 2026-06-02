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

static char *streaming_json = NULL;

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

// Register the client with the instance
void do_create_client(char *, char *);

// Receive timeline
void get_timeline(void);

// OAuth processing using authorization code
void do_oauth(char *, char *, char *);

// Post a toot
void do_toot(char *);

// Streaming toot receipt processing, assigned to stream_event_handler
static void stream_event_update(struct sjson_node *);

// Streaming notification receipt processing, assigned to stream_event_handler
static void stream_event_notify(struct sjson_node *);

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

// Streaming notification receipt processing, assigned to stream_event_handler
static void stream_event_notify(sjson_node *jobj_from_string)
{
	struct sjson_node *notify_type, *screen_name, *display_name, *status;
	const char *dname;
	if(!jobj_from_string) return;
	read_json_fom_path(jobj_from_string, "type", &notify_type);
	read_json_fom_path(jobj_from_string, "account/acct", &screen_name);
	read_json_fom_path(jobj_from_string, "account/display_name", &display_name);
	int exist_status = read_json_fom_path(jobj_from_string, "status", &status);

	putchar('\a');

	sbctx_t sb;
	sbctx_t *sbctx = &sb;

	ninitbuf(&sb);

	// Using notification type for display, so capitalize first letter
	char *t = strdup(notify_type->string_);
	t[0] = toupper((int)(unsigned char)t[0]);

	// 通知種別と誰からか[ screen_name(display_name) ]を表示
	nattron(sbctx, COLOR_PAIR(4));
	if(!noemojiflag) naddstr(sbctx, strcmp(t, "Follow") == 0 ? "👥" : strcmp(t, "Favourite") == 0 ? "💕" : strcmp(t, "Reblog") == 0 ? "🔃" : strcmp(t, "Mention") == 0 ? "🗨" : "");
	naddstr(sbctx, t);
	free(t);
	naddstr(sbctx, " from ");
	naddstr(sbctx, screen_name->string_);

	dname = display_name->string_;

	// dname(display_name)が空の場合は括弧を表示しない
	if (dname[0] != '\0') {
		naddstr(sbctx, " (");
		naddstr(sbctx, dname);
		naddstr(sbctx, ")");
	}
	naddstr(sbctx, "\n");
	nattroff(sbctx, COLOR_PAIR(4));

	sjson_tag type;

	type = status->tag;

	nflushcache(&sb);
	squeue_enqueue(sb);

	// 通知対象のTootを表示,Follow通知だとtypeがNULLになる
	if(type != SJSON_NULL && exist_status) {
		stream_event_update(status);
	}

	//wrefresh(scr);

	/*wmove(pad, pad_x, pad_y);
	wrefresh(pad);*/
}

// ストリーミングでのToot受信処理,stream_event_handlerへ代入
#define DATEBUFLEN	40
static void stream_event_update(struct sjson_node *jobj_from_string)
{
	struct sjson_node *content, *screen_name, *display_name, *reblog, *visibility;
	const char *sname, *dname, *vstr;
	struct sjson_node *created_at;
	struct tm tm;
	time_t time;
	char datebuf[DATEBUFLEN];
	if(!jobj_from_string) return;

#ifdef USE_SIXEL
	struct sjson_node *avatar, *sensitive;
	read_json_fom_path(jobj_from_string, "account/avatar", &avatar);
	read_json_fom_path(jobj_from_string, "sensitive", &sensitive);
#endif

	read_json_fom_path(jobj_from_string, "content", &content);
	read_json_fom_path(jobj_from_string, "account/acct", &screen_name);
	read_json_fom_path(jobj_from_string, "account/display_name", &display_name);

	read_json_fom_path(jobj_from_string, "reblog", &reblog);
	read_json_fom_path(jobj_from_string, "created_at", &created_at);
	read_json_fom_path(jobj_from_string, "visibility", &visibility);
	memset(&tm, 0, sizeof(tm));
	strptime(created_at->string_, "%Y-%m-%dT%H:%M:%S", &tm);
	time = timegm(&tm);
	strftime(datebuf, sizeof(datebuf), "%x(%a) %X", localtime(&time));

	vstr = visibility->string_;

	if(hidlckflag) {
		if(!strcmp(vstr, "private") || !strcmp(vstr, "direct")) {
			return;
		}
	}

#ifdef USE_SIXEL
	int fnsfw = 0;
	fnsfw = sensitive->bool_ ? 0x100 : 0;
#endif

	sjson_tag type;

	type = reblog->tag;
	sname = screen_name->string_;
	dname = display_name->string_;

	// ブーストで回ってきた場合はその旨を表示
	if(type != SJSON_NULL) {
		sbctx_t sb_reb;
		sbctx_t *sbctx_reb = &sb_reb;

		ninitbuf(&sb_reb);

		nattron(sbctx_reb,  COLOR_PAIR(3));
		if(!noemojiflag) naddstr(sbctx_reb,  "🔃 ");
		naddstr(sbctx_reb,  "Reblog by ");
		naddstr(sbctx_reb,  sname);
		// dname(表示名)が空の場合は括弧を表示しない
		if (dname[0] != '\0') {
			naddstr(sbctx_reb,  " (");
			naddstr(sbctx_reb,  dname);
			naddstr(sbctx_reb,  ")");
		}
		naddstr(sbctx_reb,  "\n");
		nattroff(sbctx_reb,  COLOR_PAIR(3));

		nflushcache(&sb_reb);
		squeue_enqueue(sb_reb);

		stream_event_update(reblog);
		return;
	}

#ifdef USE_SIXEL
	sbctx_t sb_avt;
	sbctx_t *sbctx_avt = &sb_avt;

	ninitbuf(&sb_avt);

	print_picture(sbctx_avt, avatar->string_, SIXEL_MUL_ICO);

	// アイコン右側にカーソル移動
	move_cursor_to_avatar(sbctx_avt);

	nflushcache(&sb_avt);
	squeue_enqueue(sb_avt);
	//naddstr(sbctx, "\n");
#endif

	sbctx_t sb;
	sbctx_t *sbctx = &sb;

	ninitbuf(&sb);

	// 誰からか[ screen_name(display_name) ]を表示
	nattron(sbctx,  COLOR_PAIR(1)|A_BOLD);
	naddstr(sbctx,  sname);
	nattroff(sbctx,  COLOR_PAIR(1)|A_BOLD);

	// dname(表示名)が空の場合は括弧を表示しない
	if (dname[0] != '\0') {
		nattron(sbctx,  COLOR_PAIR(2));
		naddstr(sbctx,  " (");
		naddstr(sbctx,  dname);
		naddstr(sbctx,  ")");
		nattroff(sbctx,  COLOR_PAIR(2));
	}

	if(strcmp(vstr, "public")) {
		nattron(sbctx,  COLOR_PAIR(3)|A_BOLD);
		naddstr(sbctx,  " ");
		if(noemojiflag) {
			if(!strcmp(vstr, "unlisted")) {
				naddstr(sbctx,  "<UNLIST>");
			} else if(!strcmp(vstr, "private")) {
				naddstr(sbctx,  "<PRIVATE>");
			} else {
				naddstr(sbctx,  "<!DIRECT!>");
			}
		} else {
			if(!strcmp(vstr, "unlisted")) {
				naddstr(sbctx,  "🔓");
			} else if(!strcmp(vstr, "private")) {
				naddstr(sbctx,  "🔒");
			} else {
				naddstr(sbctx,  "✉");
			}
		}
		nattroff(sbctx,  COLOR_PAIR(3)|A_BOLD);
	}

	// 日付表示
	naddstr(sbctx,  " - ");
	nattron(sbctx,  COLOR_PAIR(5));
	naddstr(sbctx,  datebuf);
	nattroff(sbctx,  COLOR_PAIR(5));
	naddstr(sbctx,  "\n");

	const char *src = content->string_;

	/*naddstr(sbctx,  src);
	naddstr(sbctx,  "\n");*/

	// タグ消去処理、2個目以降のの<p>は改行に
	int ltgt = 0;
	int pcount = 0;
	while(*src) {
		// タグならタグフラグを立てる
		if(*src == '<') ltgt = 1;

		if(ltgt && strncmp(src, "<br", 3) == 0) naddch(sbctx,  '\n');
		if(ltgt && strncmp(src, "<p", 2) == 0) {
			pcount++;
			if(pcount >= 2) {
				naddstr(sbctx,  "\n\n");
			}
		}

		// タグフラグが立っていない(=通常文字)とき
		if(!ltgt) {
			// 文字実体参照の処理
			if(*src == '&') {
				if(strncmp(src, "&amp;", 5) == 0) {
					naddch(sbctx,  '&');
					src += 4;
				}
				else if(strncmp(src, "&lt;", 4) == 0) {
					naddch(sbctx,  '<');
					src += 3;
				}
				else if(strncmp(src, "&gt;", 4) == 0) {
					naddch(sbctx,  '>');
					src += 3;
				}
				else if(strncmp(src, "&quot;", 6) == 0) {
					naddch(sbctx,  '\"');
					src += 5;
				}
				else if(strncmp(src, "&apos;", 6) == 0) {
					naddch(sbctx,  '\'');
					src += 5;
				}
				else if(strncmp(src, "&#39;", 5) == 0) {
					naddch(sbctx,  '\'');
					src += 4;
				}
			} else {
				// 通常文字
				naddch(sbctx,  *((unsigned char *)src));
			}
		}
		if(*src == '>') ltgt = 0;
		src++;
	}

	naddstr(sbctx,  "\n");

	nflushcache(&sb);
	squeue_enqueue(sb);

	// 添付メディアのURL表示
	struct sjson_node *media_attachments;

	read_json_fom_path(jobj_from_string, "media_attachments", &media_attachments);

	if(media_attachments->tag == SJSON_ARRAY) {
		for (int i = 0; i < sjson_child_count(media_attachments); ++i) {
			sbctx_t sb_att;
			sbctx_t *sbctx_att = &sb_att;

			ninitbuf(&sb_att);

			struct sjson_node *obj = sjson_find_element(media_attachments, i);
			struct sjson_node *url;
			read_json_fom_path(obj, "url", &url);
			if(url->tag == SJSON_STRING) {
				naddstr(sbctx_att,  noemojiflag ? "<LINK>" : "🔗");
				naddstr(sbctx_att,  url->string_);
				naddstr(sbctx_att,  "\n");
#ifdef USE_SIXEL
				struct sjson_node *type;
				read_json_fom_path(obj, "type", &type);
				if(!strcmp(type->string_, "image")) {
					print_picture(sbctx_att, url->string_, SIXEL_MUL_PIC | fnsfw);
					naddstr(sbctx_att,  "\n");
				}
#endif
			}

			nflushcache(&sb_att);
			squeue_enqueue(sb_att);
		}
	}

	sbctx_t sb_end;
	sbctx_t *sbctx_end = &sb_end;

	ninitbuf(&sb_end);

	// 投稿アプリ名表示
	struct sjson_node *application_name;
	int exist_appname = read_json_fom_path(jobj_from_string, "application/name", &application_name);

	// 名前が取れたときのみ表示
	if(exist_appname) {
		type = application_name->tag;

		if(type != SJSON_NULL) {
			naddstr(sbctx_end,  " - ");

			nattron(sbctx_end,  COLOR_PAIR(1));
			naddstr(sbctx_end,  "via ");
			nattroff(sbctx_end,  COLOR_PAIR(1));
			nattron(sbctx_end,  COLOR_PAIR(2));
			naddstr(sbctx_end,  application_name->string_);
			naddstr(sbctx_end,  "\n");
			nattroff(sbctx_end,  COLOR_PAIR(2));
		}
	}

	naddstr(sbctx_end, "\n\n");

	nflushcache(&sb_end);
	squeue_enqueue(sb_end);

	//wrefresh(scr);

	/*wmove(pad, pad_x, pad_y);
	wrefresh(pad);*/
}

// ストリーミングで受信したJSON(接続維持用データを取り除き一体化したもの)
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

			//sbctx_t sb;
			//ninitbuf(&sb);

			stream_event_handler(jobj_from_string);

			//nflushcache(&sb);
			//squeue_enqueue(sb);

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

			//sbctx_t sb;
			//ninitbuf(&sb);

			stream_event_update(obj);

			//nflushcache(&sb);
			//squeue_enqueue(sb);
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