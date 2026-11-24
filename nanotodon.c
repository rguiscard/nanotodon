#include <curl/curl.h>
#include <stdlib.h>
#include <stdint.h>
#include <strings.h>
#include <string.h> // memmove
#include <time.h>   // strptime, strptime, timegm, localtime
#include <ctype.h>  // isspace
#include <locale.h> // setlocale

#define SJSON_IMPLEMENT
#include "sjson.h"

#include "nanotodon.h"
#include "sbuf.h"
#include "squeue.h"
#include "utils.h"
#ifdef USE_KITTY
#include "image.h"
#endif
#include "src/headers.h"

// 受信したストリーミングを処理する関数のポインタ
static void (*stream_event_handler)(struct sjson_node *);


// ストリーミングでのToot受信処理,stream_event_handlerへ代入
static void stream_event_update(struct sjson_node *);

// ストリーミングでの通知受信処理,stream_event_handlerへ代入
static void stream_event_notify(struct sjson_node *);

// アクセストークン文字列
static char access_token[256];

// ドメイン文字列
char domain_string[256];

// 画像キャッシュのディレクトリ(nanotodon_set_cache_dir() が設定する)
static char cache_dir_path[256];

int monoflag = 0;
static int hidlckflag = 1;
static int noemojiflag = 0;

// Zig (src/stream.zig) が text/event-stream を組み立て、1イベント分のJSONを
// ここへ渡す。kind は 0=update, 1=notification。
void nanotodon_stream_dispatch(int kind, const char *json, size_t len)
{
	if (!json || len == 0) return;

	// sjson_decode() scans for a NUL terminator, which the caller guarantees one
	// byte past `len` (src/stream.zig appends it). `len` is only for validation.
	sjson_context *ctx = sjson_create_context(0, 0, NULL);
	struct sjson_node *node = sjson_decode(ctx, json);
	if (!node) {
		fprintf(stderr, "nanotodon: cannot decode a stream event (%zu bytes)\n", len);
		sjson_destroy_context(ctx);
		return;
	}

	switch (kind) {
	case 0: stream_event_update(node); break;
	case 1: stream_event_notify(node); break;
	default: break;
	}

	sjson_destroy_context(ctx);
}

// TimelineのJSON配列(api/v1/timelines/*)を受け取り、古い順に表示する。
// 新しいものが下端に来るよう、C版と同じく逆順にたどる。
void nanotodon_stream_timeline(const char *json, size_t len)
{
	if (!json || len == 0) return;

	// The caller passes a NUL-terminated copy; see nanotodon_stream_dispatch().
	sjson_context *ctx = sjson_create_context(0, 0, NULL);
	struct sjson_node *array = sjson_decode(ctx, json);
	if (!array) {
		fprintf(stderr, "nanotodon: cannot decode the timeline (%zu bytes)\n", len);
		sjson_destroy_context(ctx);
		return;
	}

	if (array->tag == SJSON_ARRAY) {
		for (int i = sjson_child_count(array) - 1; i >= 0; i--) {
			stream_event_update(sjson_find_element(array, i));
		}
	}

	sjson_destroy_context(ctx);
}


// ストリーミングでの通知受信処理,stream_event_handlerへ代入
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

	// 通知種別を表示に流用するので先頭を大文字化
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

#ifdef USE_KITTY
	// TODO(avatar): the status also carries "account/avatar" (an image URL). It is
	// not read because avatars are not rendered yet; when they come back, parse it
	// here and print it above the status body (block layout) via print_image().
	struct sjson_node *sensitive = NULL;
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

#ifdef USE_KITTY
	// 添付画像を出すか、伏せるかの判定にだけ使う
	const int sensitive_media = sensitive != NULL && sensitive->bool_;
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
#ifdef USE_KITTY
				struct sjson_node *type;
				read_json_fom_path(obj, "type", &type);
				if(type != NULL && !strcmp(type->string_, "image")) {
					if(sensitive_media) {
						naddstr(sbctx_att, "[sensitive image]\n");
					} else {
						print_image(sbctx_att, url->string_);
						naddstr(sbctx_att,  "\n");
					}
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

// CLIオプションを反映する(src/cli.zig から起動時に一度だけ呼ばれる。
// プロファイル・タイムライン・件数は Zig 側が持つので、ここには渡ってこない。
// 表示に関するものだけが C に残っている。
void nanotodon_apply_cli_options(const struct nanotodon_cli_options *o)
{
	monoflag = o->mono ? 1 : 0;
	hidlckflag = o->unlock ? 0 : 1;
	noemojiflag = o->no_emoji ? 1 : 0;
}

// ---- src/main.zig から呼ばれる起動フェーズ ----
// 順番が意味を持つので、まとめずに名前で分けてある。

// Zig(src/config.zig)が決めた画像キャッシュのディレクトリを受け取る。
// C 側に残っているパスはこれだけ(src/image.c が使う)。
void nanotodon_set_cache_dir(const char *dir)
{
	snprintf(cache_dir_path, sizeof(cache_dir_path), "%s", dir);
}

const char *nanotodon_cache_dir(void)
{
	return cache_dir_path;
}

// ヘッダ用の文字列とドメインを設定する。
void nanotodon_set_credentials(const char *auth_header, const char *domain)
{
	snprintf(access_token, sizeof(access_token), "%s", auth_header);
	snprintf(domain_string, sizeof(domain_string), "%s", domain);
}

// 端末とキューの初期化。スレッドを起動する前に済ませる。
void nanotodon_runtime(void)
{
	setlocale(LC_ALL, "");

	squeue_init();
#ifdef USE_KITTY
	image_init();
#endif
}

// ---- src/poster.zig から呼ばれるフック ----

// 読み取り専用アクセサ。どちらも nanotodon_set_credentials() 以降は変化しない。
// スレッドからそのまま読める。
const char *nanotodon_domain(void)
{
	return domain_string;
}

const char *nanotodon_auth_header(void)
{
	return access_token;
}

// ---- src/loop.zig から呼ばれるフック ----

// queueに溜まった出力を1つ表示する(なければ何もしない)
void nanotodon_pump_output(void)
{
	sbctx_t sb;

	// squeue_dequeue() は成功時に0、空の時に1を返す。以前は空のときにも
	// 未初期化の sb.buf を free して書き出していた。
	if(squeue_dequeue(&sb) == 0 && sb.buf != NULL) {
		fwrite(sb.buf, sb.bufptr, 1, stdout);
		free(sb.buf);
	}
}
