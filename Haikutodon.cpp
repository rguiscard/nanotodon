#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include "Haikutodon.h"

int main(int argc, char *argv[])
{
    config.profile_name[0] = 0;

    // オプション解析
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"-mono")) {
            monoflag = 1;
            printf("Monochrome mode.\n");
        } else if(!strcmp(argv[i],"-unlock")) {
            hidlckflag = 0;
            printf("Show DIRECT and PRIVATE.\n");
        } else if(!strcmp(argv[i],"-noemoji")) {
            noemojiflag = 1;
            printf("Hide UI emojis.\n");
        } else if(!strncmp(argv[i],"-profile",8)) {
            i++;
            if(i >= argc) {
                fprintf(stderr,"too few argments\n");
                return -1;
            } else {
                strcpy(config.profile_name,argv[i]);
                printf("Using profile: %s\n", config.profile_name);
            }
        } else if(!strncmp(argv[i],"-tllimit",8)) {
            i++;
            if(i >= argc) {
                fprintf(stderr,"too few argments\n");
                return -1;
            } else {
                limit_timeline = atoi(argv[i]);
                if(limit_timeline < 0) limit_timeline = 0;
                if(limit_timeline > 40) limit_timeline = 40;
                printf("Timeline limit: %d\n", limit_timeline);
            }
        } else if(!strncmp(argv[i],"-timeline",9)) {
            i++;
            if(i >= argc) {
                fprintf(stderr,"too few argments\n");
                return -1;
            } else {
                if(!strcmp(argv[i],"home")) {

                } else if(!strcmp(argv[i],"local")) {
                    selected_stream = "public/local";
                    selected_timeline = "public?local=true";
                } else if(!strcmp(argv[i],"public")) {
                    selected_stream = "public";
                    selected_timeline = "public?local=false";
                } else {
                    fprintf(stderr,"Unknown timeline %s\n", argv[i]);
                    return -1;
                }

                printf("Using timeline: %s\n", selected_stream);
            }
        } else {
            fprintf(stderr,"Unknown Option %s\n", argv[i]);
            return -1;
        }
    }

    nano_config_init(&config);

    char *env_lang = getenv("LANG");
    int msg_lang = 0;

    if(env_lang && !strcmp(env_lang,"ja_JP.UTF-8")) msg_lang = 1;

    // トークンファイルオープン
    FILE *fp = fopen(config.dot_token, "rb");
    if(fp) {
        // 存在すれば読み込む
        fclose(fp);
        struct sjson_context *ctx;
        char *json;
        struct sjson_node *token;
        struct sjson_node *jobj_from_file = read_json_from_file(config.dot_token, &json, &ctx);
        read_json_fom_path(jobj_from_file, "access_token", &token);
        sprintf(access_token, "Authorization: Bearer %s", token->string_);
        FILE *f2 = fopen(config.dot_domain, "rb");
        fscanf(f2, "%255s", domain_string);
        fclose(f2);
        sjson_destroy_context(ctx);
        free(json);
    } else {
        // ない場合は登録処理へ
        char domain[256];
        char *ck;
        char *cs;
        printf("%s", nano_msg_list[msg_lang][NANO_MSG_WELCOME]);
        printf("%s", nano_msg_list[msg_lang][NANO_MSG_WEL_FIRST]);
    retry1:
        printf("%s", nano_msg_list[msg_lang][NANO_MSG_INPUT_DOMAIN]);
        printf(">");
        scanf("%255s", domain);
        printf("\n");

        // ドメイン名を保存する
        FILE *f2 = fopen(config.dot_domain, "wb");
        fprintf(f2, "%s", domain);
        fclose(f2);

        char dot_ckcs[256];
        if (nano_config_app_token_filename(&config, domain, dot_ckcs, sizeof(dot_ckcs)) >= sizeof(dot_ckcs)) {
            fprintf(stderr, "FATAL: Can't allocate memory. Too long filename.\n");
            exit(EXIT_FAILURE);
        }

        char json_name[256];
        strcpy(json_name, dot_ckcs);
        strcpy(domain_string, domain);

        // クライアントキーファイルをオープン
        FILE *ckcs = fopen(json_name, "rb");
        if(!ckcs) {
            // なければ作る
            do_create_client(domain, dot_ckcs);
        } else {
            // あったら閉じる
            fclose(ckcs);
        }

        // クライアントキーファイルを読む
        struct sjson_context *ctx;
        char *json;
        struct sjson_node *cko, *cso;
        struct sjson_node *jobj_from_file = read_json_from_file(json_name, &json, &ctx);
        int r1 = read_json_fom_path(jobj_from_file, "client_id", &cko);
        int r2 = read_json_fom_path(jobj_from_file, "client_secret", &cso);
        if(!r1 || !r2) {
            // もしおかしければ最初まで戻る
            printf("%s", nano_msg_list[msg_lang][NANO_MSG_SOME_WRONG_DOMAIN]);
            remove(json_name);
            remove(config.dot_domain);
            goto retry1;
        }
        ck = strdup(cko->string_);
        cs = strdup(cso->string_);

        sjson_destroy_context(ctx);
        free(json);

        char code[256];

        printf("%s", nano_msg_list[msg_lang][NANO_MSG_AUTHCATION]);
        printf("%s", nano_msg_list[msg_lang][NANO_MSG_OAUTH_URL]);

        // 認証用URLを表示、コードを入力させる
        printf("https://%s/oauth/authorize?client_id=%s&response_type=code&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read%%20write%%20follow\n", domain, ck);
        printf(">");
        scanf("%255s", code);
        printf("\n");

        // 改行読み飛ばし
        getchar();

        // 承認コードで認証
        do_oauth(code, ck, cs);
        free(ck);
        free(cs);

        // トークンファイルを読む
        struct sjson_node *token;
        jobj_from_file = read_json_from_file(config.dot_token, &json, &ctx);
        int r3 = read_json_fom_path(jobj_from_file, "access_token", &token);
        if(!r3) {
            // もしおかしければ最初まで戻る
            printf("%s", nano_msg_list[msg_lang][NANO_MSG_SOME_WRONG_OAUTH]);
            remove(json_name);
            remove(config.dot_domain);
            remove(config.dot_token);
            goto retry1;
        }

        // httpヘッダに添付する用の形式でコピーしておく
        sprintf(access_token, "Authorization: Bearer %s", token->string_);
        printf("%s", nano_msg_list[msg_lang][NANO_MSG_FINISH]);

        sjson_destroy_context(ctx);
        free(json);
    }

    setlocale(LC_ALL, "");

    pthread_mutex_init(&prompt_mutex, NULL);
    squeue_init();
#ifdef USE_SIXEL
    sixel_init();
#endif

    pthread_t stream_thread;
    pthread_t prompt_thread;

    // ストリーミングスレッド生成
    pthread_create(&stream_thread, NULL, stream_thread_func, NULL);
    pthread_create(&prompt_thread, NULL, prompt_thread_func, NULL);

    while (1)
    {
        sbctx_t sb;
        // queueに来ていたら表示する
        if(!squeue_dequeue(&sb)) {
            fwrite(sb.buf, sb.bufptr, 1, stdout);
            free(sb.buf);
        }

        // プロンプト通知が来てたらtoot処理
        if(prompt_notify != 0) {
            fputs("> ", stdout);
            char status[1024];
            fgets(status, 1024, stdin);

            char status2[1024];
            char *p1 = status, *p2 = status2;

            for(;*p1 != 0; p1++, p2++) {
                if(*p1 == '\\') {
                    if(p1[1] == '\\') {
                        *p2 = '\\';
                        p1++;
                    }
                    if(p1[1] == 'n') {
                        *p2 = '\n';
                        p1++;
                    }
                } else {
                    *p2 = *p1;
                }
            }

            *p2 = 0;

            do_toot(status2);
            prompt_notify = 0;
        } else {
            // あまり短いと謎マシンが死ぬので100ms
            const struct timespec req = {0, 100 * 1000000};
            nanosleep(&req, NULL);
        }
    }

    return 0;
}