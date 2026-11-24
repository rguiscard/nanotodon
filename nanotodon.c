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
#include "src/headers.h"

int monoflag = 0;
static int hidlckflag = 1;
static int noemojiflag = 0;

// ---- src/main.zig から呼ばれる起動フェーズ ----

// 初期化。スレッドを起動する前に済ませる。
// setlocale() と出力は Zig (src/main.zig, src/out.zig) が持つ。
void nanotodon_runtime(void)
{
}
