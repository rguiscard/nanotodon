#include <curl/curl.h>
#include <stdlib.h>
#include <stdint.h>
#include <strings.h>
#include <string.h> // memmove
#include <time.h>   // strptime, strptime, timegm, localtime
#include <ctype.h>  // isspace
#include <locale.h> // setlocale

#include "nanotodon.h"
#include "sbuf.h"
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

// 初期化。スレッドを起動する前に済ませる。
// setlocale() と出力は Zig (src/main.zig, src/out.zig) が持つ。
void nanotodon_runtime(void)
{
#ifdef USE_KITTY
	image_init();
#endif
}
