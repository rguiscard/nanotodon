#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <ctype.h>
#include <time.h>
#include <vector>
#include <string>
#include <map>
#include <curl/curl.h>
#include <Bitmap.h>
#include <translation/TranslationUtils.h>
#include <support/DataIO.h>
#include <Messenger.h>
#include "Haikutodon.h"
#include "sbuf.h"

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
#include <GroupLayout.h>
#include <StringView.h>
#include <Button.h>

// Message constant for toot data
enum {
	TOOT_MSG = 'toot',
	AVATAR_DOWNLOADED = 'avdl'
};

// Avatar cache
static std::map<std::string, BBitmap*> g_avatar_cache;
static pthread_mutex_t g_avatar_mutex = PTHREAD_MUTEX_INITIALIZER;
static BMessenger g_main_window_messenger;

// Callback for curl to write data into memory
struct MemoryStruct {
	char *memory;
	size_t size;
};

static size_t WriteMemoryCallback(void *contents, size_t size, size_t nmemb, void *userp) {
	size_t realsize = size * nmemb;
	struct MemoryStruct *mem = (struct MemoryStruct *)userp;

	char *ptr = (char *)realloc(mem->memory, mem->size + realsize + 1);
	if(ptr == NULL) return 0;

	mem->memory = ptr;
	memcpy(&(mem->memory[mem->size]), contents, realsize);
	mem->size += realsize;
	mem->memory[mem->size] = 0;

	return realsize;
}

// Background thread to download avatar
static void* avatar_download_thread(void* arg) {
	std::string* url = (std::string*)arg;
	
	CURL *curl_handle;
	CURLcode res;
	struct MemoryStruct chunk;

	chunk.memory = (char *)malloc(1);
	chunk.size = 0;

	curl_handle = curl_easy_init();
	curl_easy_setopt(curl_handle, CURLOPT_URL, url->c_str());
	curl_easy_setopt(curl_handle, CURLOPT_WRITEFUNCTION, WriteMemoryCallback);
	curl_easy_setopt(curl_handle, CURLOPT_WRITEDATA, (void *)&chunk);
	curl_easy_setopt(curl_handle, CURLOPT_USERAGENT, "libcurl-agent/1.0");
	curl_easy_setopt(curl_handle, CURLOPT_FOLLOWLOCATION, 1L);

	res = curl_easy_perform(curl_handle);
	curl_easy_cleanup(curl_handle);

	if(res == CURLE_OK && chunk.size > 0) {
		BMemoryIO memIO(chunk.memory, chunk.size);
		BBitmap* bitmap = BTranslationUtils::GetBitmap(&memIO);
		
		if(bitmap) {
			pthread_mutex_lock(&g_avatar_mutex);
			g_avatar_cache[*url] = bitmap;
			pthread_mutex_unlock(&g_avatar_mutex);
			
			// Notify main window to redraw
			if (g_main_window_messenger.IsValid()) {
				BMessage msg(AVATAR_DOWNLOADED);
				msg.AddString("url", url->c_str());
				g_main_window_messenger.SendMessage(&msg);
			}
		}
	}

	free(chunk.memory);
	delete url;
	return NULL;
}

static void request_avatar_download(const std::string& url) {
	pthread_mutex_lock(&g_avatar_mutex);
	if(g_avatar_cache.find(url) != g_avatar_cache.end() || g_avatar_cache.find(url + "_pending") != g_avatar_cache.end()) {
		pthread_mutex_unlock(&g_avatar_mutex);
		return; // Already cached or pending
	}
	g_avatar_cache[url + "_pending"] = NULL; // Mark as pending
	pthread_mutex_unlock(&g_avatar_mutex);

	pthread_t thread;
	std::string* url_copy = new std::string(url);
	pthread_create(&thread, NULL, avatar_download_thread, url_copy);
	pthread_detach(thread);
}

class AvatarView : public BView {
public:
	AvatarView(const std::string& url)
		: BView("avatar_view", B_WILL_DRAW), fUrl(url)
	{
		SetExplicitMaxSize(BSize(60, 60));
		SetExplicitMinSize(BSize(60, 60));
	}

	void UpdateIfNeeded() {
		// Trigger a redraw; Draw() will check the cache
		Invalidate();
	}

	void Draw(BRect updateRect) {
		BBitmap* cachedBitmap = NULL;
		pthread_mutex_lock(&g_avatar_mutex);
		auto it = g_avatar_cache.find(fUrl);
		if (it != g_avatar_cache.end() && it->second != NULL) {
			cachedBitmap = it->second;
		}
		pthread_mutex_unlock(&g_avatar_mutex);

		if(cachedBitmap) {
			// Scale the bitmap to fit the 60x60 bounds
			DrawBitmap(cachedBitmap, cachedBitmap->Bounds(), Bounds(), B_FILTER_BITMAP_BILINEAR);
		} else {
			// Placeholder
			SetHighColor(ui_color(B_PANEL_BACKGROUND_COLOR));
			FillRect(updateRect);
			SetHighColor(ui_color(B_SHINE_COLOR));
			StrokeRect(updateRect);
		}
	}

private:
	std::string fUrl;
};

class TootView : public BView {
public:
	TootView(const char* content, const char* account = "@username", const char* display_name = "Display Name", const char* avatar_url = "")
		: BView("toot_view", B_WILL_DRAW), fAvatarUrl(avatar_url ? avatar_url : "")
	{
		fAvatarView = new AvatarView(fAvatarUrl);

		BStringView* nameView = new BStringView("name_view", display_name);
		nameView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNSET));
		
		BStringView* handleView = new BStringView("handle_view", account);
		handleView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNSET));

		BStringView* dateView = new BStringView("date_view", "Date");
		dateView->SetAlignment(B_ALIGN_RIGHT);
		dateView->SetExplicitMaxSize(BSize(100, 60));
		dateView->SetExplicitMinSize(BSize(100, 60));

		BView* headerView = BLayoutBuilder::Group<>(B_HORIZONTAL)
			.Add(fAvatarView)
			.AddGroup(B_VERTICAL)
				.Add(nameView)
				.Add(handleView)
			.End()
			.Add(dateView)
			.View();
		headerView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, 60));
		headerView->SetExplicitMinSize(BSize(B_SIZE_UNSET, 60));

		// Row 2: Content
		fContentView = new BTextView("content_view", B_WILL_DRAW);
		fContentView->SetText(content ? content : "");
		fContentView->SetWordWrap(true);
		fContentView->SetViewColor(ui_color(B_PANEL_BACKGROUND_COLOR));
		fContentView->MakeEditable(false);
		fContentView->SetExplicitMaxSize(BSize(B_SIZE_UNSET, 80));
		fContentView->SetExplicitMinSize(BSize(B_SIZE_UNSET, 80));

		// Row 3: Actions
		BView* actionsView = BLayoutBuilder::Group<>(B_HORIZONTAL)
			.AddGroup(B_HORIZONTAL, 0.0f)
				.Add(new BButton("reply_button", "Reply", NULL))
				.Add(new BButton("boost_button", "Boost", NULL))
				.Add(new BButton("like_button", "Like", NULL))
				.Add(new BButton("bookmark_button", "Bookmark", NULL))
				.Add(new BButton("more_button", "More...", NULL))
				.SetExplicitAlignment(BAlignment(B_ALIGN_LEFT, B_ALIGN_TOP))
			.End()
			.AddGlue()
			.View();

		// Divider line
		BView* dividerView = new BView("divider", B_WILL_DRAW);
		dividerView->SetViewColor(ui_color(B_SHADOW_COLOR));
		dividerView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, 1));
		dividerView->SetExplicitMinSize(BSize(B_SIZE_UNSET, 1));

		// Main layout
		BLayoutBuilder::Group<>(this, B_VERTICAL)
			.Add(headerView)
			.Add(fContentView)
			.Add(actionsView)
			.Add(dividerView)
			.SetInsets(5, 5, 5, 0);

		// Trigger download if not already in cache
		if (!fAvatarUrl.empty()) {
			pthread_mutex_lock(&g_avatar_mutex);
			bool in_cache = (g_avatar_cache.find(fAvatarUrl) != g_avatar_cache.end());
			pthread_mutex_unlock(&g_avatar_mutex);
			
			if (!in_cache) {
				request_avatar_download(fAvatarUrl);
			}
		}
	}

	void UpdateAvatarIfNeeded(const std::string& url) {
		if (fAvatarUrl == url) {
			fAvatarView->UpdateIfNeeded();
		}
	}

	~TootView() {}

private:
	std::string fAvatarUrl;
	BTextView* fContentView;
	AvatarView* fAvatarView;
};

// Helper to strip HTML entities and tags, returning clean text
static char* strip_html(const char* src)
{
	if (!src) return NULL;
	sbctx_t sb;
	sbctx_t *sbctx = &sb;
	ninitbuf(&sb);
	
	int ltgt = 0;
	while(*src) {
		if(*src == '<') ltgt = 1;
		
		if(ltgt && strncmp(src, "<br", 3) == 0) naddch(sbctx, '\n');
		if(ltgt && strncmp(src, "<p", 2) == 0) naddstr(sbctx, "\n\n");
		
		if(!ltgt) {
			if(*src == '&') {
				if(strncmp(src, "&amp;", 5) == 0) { naddch(sbctx, '&'); src += 4; }
				else if(strncmp(src, "&lt;", 4) == 0) { naddch(sbctx, '<'); src += 3; }
				else if(strncmp(src, "&gt;", 4) == 0) { naddch(sbctx, '>'); src += 3; }
				else if(strncmp(src, "&quot;", 6) == 0) { naddch(sbctx, '"'); src += 5; }
				else if(strncmp(src, "&apos;", 6) == 0) { naddch(sbctx, '\''); src += 5; }
				else if(strncmp(src, "&#39;", 5) == 0) { naddch(sbctx, '\''); src += 4; }
				else { naddch(sbctx, *src); }
			} else {
				naddch(sbctx, *((unsigned char *)src));
			}
		}
		if(*src == '>') ltgt = 0;
		src++;
	}
	nflushcache(&sb);
	
	char* result = (char*)malloc(sb.bufptr + 1);
	if (result) {
		memcpy(result, sb.buf, sb.bufptr);
		result[sb.bufptr] = '\0';
	}
	free(sb.buf);
	return result;
}

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
		g_main_window_messenger = BMessenger(this);
		SetFlags(Flags() | B_QUIT_ON_WINDOW_CLOSE);

		BMenuBar* menuBar = new BMenuBar("menu_bar");
		BMenu* fileMenu = new BMenu("File");
		fileMenu->AddItem(new BMenuItem("Quit", new BMessage('quit'), 'Q', B_COMMAND_KEY));
		menuBar->AddItem(fileMenu);

		fContentView = new BView("content_view", B_WILL_DRAW);
		fGroupLayout = new BGroupLayout(B_VERTICAL);
		fContentView->SetLayout(fGroupLayout);
		fContentView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNLIMITED));
		fContentView->SetExplicitMinSize(BSize(B_SIZE_UNSET, B_SIZE_UNSET));

#if 0
                fGroupLayout->AddView(new TootView("1"));
                fGroupLayout->AddView(new TootView("2"));
                fGroupLayout->AddView(new TootView("3"));
                fGroupLayout->AddView(new TootView("4"));
                fGroupLayout->AddView(new TootView("5"));
                fGroupLayout->AddView(new TootView("6"));
                fGroupLayout->AddView(new TootView("7"));
#endif

		fScrollView = new BScrollView("scroll_view", fContentView, 0, false, true);
		fScrollView->SetExplicitMinSize(BSize(50, 50));
		fScrollView->SetExplicitMaxSize(BSize(B_SIZE_UNSET, B_SIZE_UNLIMITED));

		fInputView = new BTextView("input_view", B_WILL_DRAW);
		fInputView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNSET));
		BScrollView* inputScrollView = new BScrollView("input_scroll_view", fInputView, 0, false, true);
		inputScrollView->SetExplicitMinSize(BSize(B_SIZE_UNSET, 30));
		inputScrollView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNLIMITED));

		fSplitView = BLayoutBuilder::Split<>(B_VERTICAL)
			.Add(fScrollView, 0.7f)
			.Add(inputScrollView, 0.3f)
			.SetCollapsible(0, false)
			.SetCollapsible(1, true);
		fSplitView->SetExplicitMinSize(BSize(B_SIZE_UNSET, 100));
		fSplitView->SetExplicitMaxSize(BSize(B_SIZE_UNLIMITED, B_SIZE_UNLIMITED));

		fSendButton = new BButton("send_button", "Send", new BMessage('send'));

		BLayoutBuilder::Group<>(this, B_VERTICAL)
			.Add(menuBar)
			.Add(fSplitView)
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
			case AVATAR_DOWNLOADED: {
				if (LockLooper()) {
					const char* url = message->FindString("url");
					if (url) {
						int32 count = fGroupLayout->CountItems();
						for (int32 i = 0; i < count; i++) {
							BLayoutItem* item = fGroupLayout->ItemAt(i);
							if (item && item->View()) {
								TootView* tootView = dynamic_cast<TootView*>(item->View());
								if (tootView) {
									tootView->UpdateAvatarIfNeeded(url);
								}
							}
						}
					}
					UnlockLooper();
				}
				break;
			}
			default:
				BWindow::MessageReceived(message);
		}
	}

	void ProcessQueue(void) {
		queue_item_t item;
//		BGroupLayout* layout = static_cast<BGroupLayout*>(fContentView->GetLayout());
		if (LockLooper()) {
		while (!squeue_dequeue_raw(&item)) {
			BMessage msg;
			status_t err = msg.Unflatten((const char*)item.data);
			free(item.data);
			
			if (err == B_OK) {
				const char *content = msg.FindString("content");
				if (content) {
					const char *account = msg.FindString("account");
					const char *display_name = msg.FindString("display_name");
					const char *avatar_url = msg.FindString("avatar_url");
					TootView* tootView = new TootView(content, account ? account : "@username", display_name ? display_name : "Display Name", avatar_url ? avatar_url : "");
					fGroupLayout->AddView(tootView);
				} else {
#if 0
					const char *raw = msg.FindString("raw");
					if (raw) {
						TootView* tootView = new TootView(raw, 500.0f);
						BGroupLayout* layout = static_cast<BGroupLayout*>(fContentView->GetLayout());
						layout->AddView(tootView);
						fContentView->ResizeToPreferred();
						fContentView->Layout(false);
						fScrollView->ResizeToPreferred();
					}
#endif
				}
			}
		}
		fGroupLayout->Owner()->InvalidateLayout(true);
		fSplitView->InvalidateLayout(true);
		UnlockLooper();
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
	BView* fContentView;
	BScrollView* fScrollView;
	BTextView* fInputView;
	BButton* fSendButton;
	BSplitView* fSplitView;
	BGroupLayout* fGroupLayout;
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
	
	struct sjson_node *avatar;
	read_json_fom_path(jobj_from_string, "account/avatar", &avatar);
	if (avatar && avatar->string_)
		msg.AddString("avatar_url", avatar->string_);
	
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

    MainWindow* window = new MainWindow(BRect(100, 100, 600, 600));
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
