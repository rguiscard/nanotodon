# nanotodon rewritten

Mastodon Client in two parts, a long running 'nanotodon' to display current timeline, and a tool 'toot' for posting. The idea is to have the long running 'nanotodon' to handle all incoming information and outcomoing one comes from one-shot 'toot' tool.

## Build

- zig 0.17.1

```
$ zig build
```

## Usage

```
$ nanotodon
```

For the first time, it requests the access token from your masmtodon account. After that, it just display the latest toots

```
$ toot hello (or any other message
```

This is a one-shot command line tool to post the toot through nanotodon.

### nanotodon

# オプション
- ```-mono```  
  - 色付け無効化(太字のみ有効)(for 1bpp framebuffer)

- ```-unlock```  
  - 公開範囲が PRIVATE/DIRECT の投稿を表示する

- ```-noemoji```  
  - ReblogやFavourite、公開範囲表示などのUI要素に絵文字を利用しない

- ```-profile <name>```  
  - プロファイル ``<name>`` を利用する

- ```-timeline <public|local|home>```  
  - (WIP)流すタイムラインの選択

- ```-tllimit <num>```  
  - (WIP)起動時にrest APIで取得するトゥート数の指定(デフォルトは 20)

### toot

```
$ toot hello (or any other message
$ toot -v public (or unlisted, private and direct) hello
$ toot -v private << EOF
multiple
line
message
EOF
```
