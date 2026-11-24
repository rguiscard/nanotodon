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

// アクセストークン文字列
static char access_token[256];

// ドメイン文字列
char domain_string[256];

// 画像キャッシュのディレクトリ(nanotodon_set_cache_dir() が設定する)
static char cache_dir_path[256];

int monoflag = 0;
static int hidlckflag = 1;
static int noemojiflag = 0;

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
