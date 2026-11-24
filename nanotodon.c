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

// 画像キャッシュのディレクトリ(nanotodon_set_cache_dir() が設定する)
static char cache_dir_path[256];

int monoflag = 0;
static int hidlckflag = 1;
static int noemojiflag = 0;

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

// 端末とキューの初期化。スレッドを起動する前に済ませる。
// setlocale() は Zig (src/main.zig) が呼ぶ。
void nanotodon_runtime(void)
{
	squeue_init();
#ifdef USE_KITTY
	image_init();
#endif
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
