#include "HtmlView.h"
#include <LayoutBuilder.h>
#include <stdio.h>
#include <File.h>
#include <String.h>
#include <string>
#include <iostream>
#include <Roster.h>
#include <Entry.h>

HtmlView::HtmlView(BRect frame, const char* name)
    : BTextView(name, B_WILL_DRAW),
    fDefaultFont(be_plain_font)
{
    ResizeTo(frame.Width(), frame.Height());
    SetFont(&fDefaultFont);
    MakeEditable(false);
}

HtmlView::~HtmlView()
{
}

int HtmlView::_get_newline_count(const char* tag) const
{
    if (!tag) return 1;
    
    if (strcmp(tag, "p") == 0) return 2;
    if (strcmp(tag, "h1") == 0 || strcmp(tag, "h2") == 0 || 
        strcmp(tag, "h3") == 0 || strcmp(tag, "h4") == 0 || 
        strcmp(tag, "h5") == 0 || strcmp(tag, "h6") == 0) {
        return 1;
    }
    return 1;
}

void HtmlView::_extract_text(const litehtml::element::ptr& el)
{
    if (!el) return;
    
    if (el->is_text()) {
        litehtml::string txt;
        el->get_text(txt);
        if (!txt.empty()) {
            fPlainText += txt;
        }
        return;
    }
    
    const char* tag = el->get_tagName();
    
    if (tag && strcmp(tag, "br") == 0) {
        if (!fPlainText.empty()) {
            fPlainText += "\n";
        }
        return;
    }
    
    size_t startOffset = fPlainText.length();
    
    for (const auto& child : el->children()) {
        _extract_text(child);
    }
    
    size_t endOffset = fPlainText.length();
    
    if (!el->is_inline() && !fPlainText.empty()) {
        int count = _get_newline_count(el->get_tagName());
        for (int i = 0; i < count; i++) {
            fPlainText += "\n";
        }
    }
    
    if (tag && strcmp(tag, "a") == 0) {
        const char* href = el->get_attr("href");
        if (href && endOffset > startOffset) {
            LinkRange link;
            link.offset = startOffset;
            link.length = endOffset - startOffset;
            link.url = href;
            fLinks.push_back(link);
        }
    }
}

void HtmlView::RenderHtml(const BString& html)
{
    fPlainText.clear();
    fLinks.clear();
    BString cleanHtml(html);
    cleanHtml.RemoveAll("\n");
    cleanHtml.RemoveAll("\r");
    fDocument = litehtml::document::createFromString(cleanHtml.String(), this);
    if (fDocument) {
        fDocument->render((int)Bounds().Width() - 20);
        if (fDocument->root()) {
            _extract_text(fDocument->root());
        }
    }
    while (!fPlainText.empty() && fPlainText.back() == '\n') {
        fPlainText.pop_back();
    }
    
    // Debug output for link ranges
#if 0
    for (const auto& link : fLinks) {
        std::cout << "Link: offset=" << link.offset << " length=" << link.length 
            << " url=" << link.url << std::endl;
    }
#endif
    
    BRect textRect = Bounds();
    textRect.bottom = textRect.top + 5000;
    SetTextRect(textRect);
    SetText(fPlainText.c_str());
}

void HtmlView::MouseDown(BPoint where)
{
    int32 offset = OffsetAt(where);
    for (const auto& link : fLinks) {
        if (offset >= (int32)link.offset && offset < (int32)(link.offset + link.length)) {
            const char* url = link.url.String();
            be_roster->Launch("text/html", 1, &url);
            return;
        }
    }
    BTextView::MouseDown(where);
}

// litehtml::document_container implementation
litehtml::uint_ptr HtmlView::create_font(const char* faceName, int size, int weight, 
    litehtml::font_style italic, unsigned int decoration, 
    litehtml::font_metrics* fm)
{
    (void)faceName; (void)size; (void)weight; (void)italic; (void)decoration;
    if (fm) {
        font_height fh;
        fDefaultFont.GetHeight(&fh);
        fm->ascent = (int)fh.ascent;
        fm->descent = (int)fh.descent;
        fm->height = (int)fDefaultFont.Size();
    }
    return (litehtml::uint_ptr)&fDefaultFont;
}

void HtmlView::delete_font(litehtml::uint_ptr hFont)
{
    (void)hFont;
}

int HtmlView::text_width(const char* text, litehtml::uint_ptr hFont)
{
    font_height fh;
    BFont* font = (BFont*)hFont;
    font->GetHeight(&fh);
    return (int)font->StringWidth(text);
}

void HtmlView::draw_text(litehtml::uint_ptr hdc, const char* text, litehtml::uint_ptr hFont, 
    litehtml::web_color color, const litehtml::position& pos)
{
    (void)hdc; (void)hFont; (void)color; (void)pos; (void)text;
}

int HtmlView::pt_to_px(int pt) const
{
    // Standard conversion: 1 pt = 1.333 px (96 dpi / 72 dpi)
    return (int)(pt * 96.0 / 72.0 + 0.5);
}

int HtmlView::get_default_font_size() const
{
    return (int)fDefaultFont.Size();
}

const char* HtmlView::get_default_font_name() const
{
    font_family fam;
    font_style style;
    fDefaultFont.GetFamilyAndStyle(&fam, &style);
    static char fontName[B_FONT_FAMILY_LENGTH];
    strlcpy(fontName, fam, sizeof(fontName));
    return fontName;
}

void HtmlView::draw_list_marker(litehtml::uint_ptr hdc, const litehtml::list_marker& marker)
{
    (void)hdc; (void)marker;
}

void HtmlView::load_image(const char* src, const char* baseurl, bool redraw_on_ready)
{
    (void)src; (void)baseurl; (void)redraw_on_ready;
}

void HtmlView::get_image_size(const char* src, const char* baseurl, litehtml::size& sz)
{
    (void)src; (void)baseurl;
    sz.width = 0;
    sz.height = 0;
}

void HtmlView::draw_background(litehtml::uint_ptr hdc, const std::vector<litehtml::background_paint>& bg_list)
{
    (void)hdc; (void)bg_list;
}

void HtmlView::draw_borders(litehtml::uint_ptr hdc, const litehtml::borders& borders, 
    const litehtml::position& draw_pos, bool root)
{
    (void)hdc; (void)borders; (void)draw_pos; (void)root;
}

void HtmlView::set_caption(const char* caption)
{
    (void)caption;
}

void HtmlView::set_base_url(const char* base_url)
{
    (void)base_url;
}

void HtmlView::link(const std::shared_ptr<litehtml::document>& doc, 
    const litehtml::element::ptr& el)
{
    (void)doc; (void)el;
}

void HtmlView::on_anchor_click(const char* url, 
    const litehtml::element::ptr& anchor)
{
    (void)url; (void)anchor;
}

void HtmlView::set_cursor(const char* cursor)
{
    (void)cursor;
}

void HtmlView::transform_text(litehtml::string& text, litehtml::text_transform tt)
{
    (void)text; (void)tt;
}

void HtmlView::import_css(litehtml::string& text, const litehtml::string& url, 
    litehtml::string& baseUrl)
{
    (void)text; (void)url; (void)baseUrl;
}

void HtmlView::set_clip(const litehtml::position& pos, 
    const litehtml::border_radiuses& bdr_radius)
{
    (void)pos; (void)bdr_radius;
}

void HtmlView::del_clip()
{
}

std::shared_ptr<litehtml::element> HtmlView::create_element(
    const char* tag_name, const litehtml::string_map& attributes,
    const std::shared_ptr<litehtml::document>& doc)
{
    (void)tag_name; (void)attributes; (void)doc;
    return nullptr;
}

void HtmlView::get_media_features(litehtml::media_features& media) const
{
    litehtml::position client;
    get_client_rect(client);
    media.type = litehtml::media_type_screen;
    media.width = client.width;
    media.height = client.height;
    BRect bounds(Bounds());
    media.device_width = (int)bounds.Width();
    media.device_height = (int)bounds.Height();
    media.color = 8;
    media.color_index = 0;
    media.monochrome = 0;
    media.resolution = 96;
}

void HtmlView::get_language(litehtml::string& language, 
    litehtml::string& culture) const
{
    (void)language; (void)culture;
}

void HtmlView::get_client_rect(litehtml::position& client) const
{
    BRect bounds(Bounds());
    client.width = (int)bounds.Width();
    client.height = (int)bounds.Height();
    client.x = (int)bounds.left;
    client.y = (int)bounds.top;
}
