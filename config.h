#ifndef NANOTODON_CONFIG_H
#define NANOTODON_CONFIG_H

#include <stdlib.h>

struct nanotodon_config {
	char profile_name[256];

	char root_dir[256];
	char dot_token[256];
	char dot_domain[256];

	char cache_dir[256];
};

int nano_config_init(struct nanotodon_config *);

// 設定ディレクトリ(root_dir, cache_dir)の決定と作成だけを行う。
// トークン/ドメインファイルのパスは計算しない。
void nano_config_init_dirs(struct nanotodon_config *);

int nano_config_app_token_filename(struct nanotodon_config *, const char *, char *, size_t);

#endif
