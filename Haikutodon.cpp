#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <ctype.h>
#include <time.h>
#include "Haikutodon.h"

#include <Application.h>
#include <Window.h>
#include <View.h>
#include <MenuBar.h>
#include <Menu.h>
#include <MenuItem.h>
#include <Message.h>
#include <TextView.h>
#include <ScrollView.h>
#include <MessageRunner.h>
#include <LayoutBuilder.h>
#include <Button.h>

// Message constant for toot data
enum {
	TOOT_MSG = 'toot'
};

// Helper to queue sbctx_t data as BMessage (raw string as fallback)
static void queue_sbctx(sbctx_t *sbctx)
{
	if (sbctx->cacheptr > 0) {
		nflushcache(sbctx);
	}
	if (sbctx->buf && sbctx->bufptr > 0) {
		BMessage msg(TOOT_MSG);
		// Add raw string data
		char *null_term = (char*)malloc(sbctx->bufptr + 1);
		if (null_term) {
			memcpy(null_term, sbctx->buf, sbctx->bufptr);
			null_term[sbctx->bufptr] = '\0';
			msg.AddString("raw", null_term);
			free(null_term);
		}
		ssize_t flat_size = msg.FlattenedSize();
		char *flat_buf = (char*)malloc(flat_size);
		if (flat_buf) {
			msg.Flatten(flat_buf, flat_size);
			squeue_enqueue_raw(flat_buf, flat_size);
		}
	}
}

// Helper to queue BMessage with full toot data
static void queue_message(BMessage *msg)
{
	ssize_t flat_size = msg->FlattenedSize();
	char *flat_buf = (char*)malloc(flat_size);
	if (flat_buf) {
		msg->Flatten(flat_buf, flat_size);
		squeue_enqueue_raw(flat_buf, flat_size);
	}
}

class MainWindow : public BWindow {
public:
	MainWindow(BRect frame)
		: BWindow(frame, "Haikutodon", B_TITLED_WINDOW, B_ASYNCHRONOUS_CONTROLS)
	{
		SetFlags(Flags() | B_QUIT_ON_WINDOW_CLOSE);

		BMenuBar* menuBar = new BMenuBar("menu_bar");
		BMenu* fileMenu = new BMenu("File");
		fileMenu->AddItem(new BMenuItem("Quit", new BMessage('quit'), 'Q', B_COMMAND_KEY));
		menuBar->AddItem(fileMenu);

		fTextView = new BTextView(BRect(0, 0, 10000, 10000), "text_view", BRect(0, 0, 10000, 10000), B_FOLLOW_ALL_SIDES, B_WILL_DRAW);
		BScrollView* scrollView = new BScrollView("scroll_view", fTextView, 0, false, true);

		fInputView = new BTextView(BRect(0, 0, 10000, 1000), "input_view", BRect(0, 0, 10000, 1000), B_FOLLOW_ALL_SIDES, B_WILL_DRAW);
		BScrollView* inputScrollView = new BScrollView("input_scroll_view", fInputView, 0, false, true);

		fSendButton = new BButton("send_button", "Send", new BMessage('send'));

		BSplitView* splitView = new BSplitView(B_VERTICAL, 0.0f);
		splitView->AddChild(scrollView, 0.7f);
		splitView->AddChild(inputScrollView, 0.3f);

		BLayoutBuilder::Group<>(this, B_VERTICAL)
			.Add(menuBar)
			.Add(splitView)
			.Add(fSendButton)
			.End();
	}

	virtual void MessageReceived(BMessage* message) {
		switch (message->what) {
			case 'quit':
				be_app->PostMessage(B_QUIT_REQUESTED);
				break;
			case 'poll':
				ProcessQueue();
				break;
			case 'send':
				PostToot();
				break;
			default:
				BWindow::MessageReceived(message);
		}
	}

	void ProcessQueue(void) {
		queue_item_t item;
		while (!squeue_dequeue_raw(&item)) {
			BMessage msg;
			status_t err = msg.Unflatten((const char*)item.data);
			free(item.data);
			
			if (err == B_OK) {
				const char *content = msg.FindString("content");
				if (content) {
					fTextView->Insert(content, strlen(content), NULL);
					fTextView->Insert("\n\n", 2, NULL);
					fTextView->ScrollToSelection();
				}
			}
		}
	}

	void PostToot(void) {
		const char* text = fInputView->Text();
		if (text && *text) {
			do_toot(const_cast<char*>(text));
			fInputView->SetText("");
		}
	}

private:
	BTextView* fTextView;
	BTextView* fInputView;
	BButton* fSendButton;
};

static MainWindow* gMainWindow = NULL;

void stream_event_update(sjson_node *jobj_from_string)
{
	sjson_node *content, *screen_name, *display_name, *reblog, *visibility;
	const char *sname, *dname, *vstr;
	sjson_node *created_at;
	struct tm tm;
	time_t time;
#define DATEBUFLEN 40
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

		queue_sbctx(&sb_reb);

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

	queue_sbctx(&sb_avt);
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
					naddch(sbctx,  '"');
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
	
	// Create BMessage with structured toot data
	BMessage msg(TOOT_MSG);
	msg.AddString("raw", sb.buf);
	if (screen_name && screen_name->string_)
		msg.AddString("account", screen_name->string_);
	if (display_name && display_name->string_ && display_name->string_[0])
		msg.AddString("display_name", display_name->string_);
	if (content && content->string_)
		msg.AddString("content", content->string_);
	if (created_at && created_at->string_)
		msg.AddString("created_at", created_at->string_);
	if (visibility && vstr)
		msg.AddString("visibility", vstr);
	if (datebuf && datebuf[0])
		msg.AddString("date", datebuf);
	
	queue_message(&msg);

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

			queue_sbctx(&sb_att);
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

	// For media/app footer, just send the raw string (already BMessage-wrapped)
	queue_sbctx(&sb_end);
}

void stream_event_notify(struct sjson_node *jobj_from_string)
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
	
	BMessage msg(TOOT_MSG);
	msg.AddString("raw", sb.buf);
	msg.AddString("type", notify_type->string_);
	if (screen_name && screen_name->string_)
		msg.AddString("account", screen_name->string_);
	if (display_name && display_name->string_ && display_name->string_[0])
		msg.AddString("display_name", display_name->string_);
	queue_message(&msg);

	// 通知対象のTootを表示,Follow通知だとtypeがNULLになる
	if(type != SJSON_NULL && exist_status) {
		stream_event_update(status);
	}
}

int main(int argc, char *argv[])
{
    config.profile_name[0] = 0;

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

    FILE *fp = fopen(config.dot_token, "rb");
    if(fp) {
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

        FILE *ckcs = fopen(json_name, "rb");
        if(!ckcs) {
            do_create_client(domain, dot_ckcs);
        } else {
            fclose(ckcs);
        }

        struct sjson_context *ctx;
        char *json;
        struct sjson_node *cko, *cso;
        struct sjson_node *jobj_from_file = read_json_from_file(json_name, &json, &ctx);
        int r1 = read_json_fom_path(jobj_from_file, "client_id", &cko);
        int r2 = read_json_fom_path(jobj_from_file, "client_secret", &cso);
        if(!r1 || !r2) {
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

        printf("https://%s/oauth/authorize?client_id=%s&response_type=code&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read%%20write%%20follow\n", domain, ck);
        printf(">");
        scanf("%255s", code);
        printf("\n");

        getchar();

        do_oauth(code, ck, cs);
        free(ck);
        free(cs);

        struct sjson_node *token;
        jobj_from_file = read_json_from_file(config.dot_token, &json, &ctx);
        int r3 = read_json_fom_path(jobj_from_file, "access_token", &token);
        if(!r3) {
            printf("%s", nano_msg_list[msg_lang][NANO_MSG_SOME_WRONG_OAUTH]);
            remove(json_name);
            remove(config.dot_domain);
            remove(config.dot_token);
            goto retry1;
        }

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

    BApplication app("application/x-vnd.haikutodon");

    MainWindow* window = new MainWindow(BRect(100, 100, 600, 400));
    window->Show();

    bigtime_t interval = 100000;
    BMessage pollMessage('poll');
    BMessageRunner* runner = new BMessageRunner(window, &pollMessage, interval, -1);

    pthread_t stream_thread;
    pthread_create(&stream_thread, NULL, stream_thread_func, NULL);

    be_app->Run();

    delete runner;
    return 0;
}
