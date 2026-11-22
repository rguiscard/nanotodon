#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#include "config.h"

#define MAKE_CONFIG_DIR_OK 0x00
#define MAKE_CONFIG_DIR_CANT_CREATE 0x01
#define MAKE_CONFIG_DIR_FILE_EXISTS 0x02

#define APP_TOKEN_DIR "/app_token"

static int make_config_dir(const char *);
static void make_config_dir_or_die(const char *);

static int make_config_dir(const char* path)
{
	// existence check
	struct stat st;
	if (stat(path, &st) == 0) {
		if ((st.st_mode & S_IFMT) == S_IFDIR) {
			return MAKE_CONFIG_DIR_OK;
		}

		// exists other entry
		return MAKE_CONFIG_DIR_FILE_EXISTS;
	}

	if (errno == ENOENT && mkdir(path, 0755) == 0) {
		return MAKE_CONFIG_DIR_OK;
	}

	return MAKE_CONFIG_DIR_CANT_CREATE;
}

static void make_config_dir_or_die(const char* path)
{
	int result = make_config_dir(path);

	switch (result)
	{
	case MAKE_CONFIG_DIR_OK:
		return;
	case MAKE_CONFIG_DIR_CANT_CREATE:
		fprintf(stderr, "FATAL: Can't create directory '%s' (%s)\n", path, strerror(errno));
		exit(EXIT_FAILURE);
	case MAKE_CONFIG_DIR_FILE_EXISTS:
		fprintf(stderr, "FATAL: File already exists '%s'\n", path);
		exit(EXIT_FAILURE);
	default:
		fprintf(stderr, "FATAL: Undefined error (%s)\n", strerror(errno));
		exit(EXIT_FAILURE);
	}
}


int nano_config_app_token_filename(struct nanotodon_config *config, const char* domain, char *buf, size_t buf_length)
{
	const size_t path_length = strlen(config->root_dir) + strlen(APP_TOKEN_DIR) + 1 + strlen(domain);
	if (path_length >= buf_length) {
		// 予測パス長がバッファに収まりきらない場合は、何もしないで予測パス長を返す
		return path_length;
	}

	strcpy(buf, config->root_dir);
	strcat(buf, APP_TOKEN_DIR);
	make_config_dir_or_die(buf);

	strcat(buf, "/");
	strcat(buf, domain);
	return path_length;
}
