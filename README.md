# nanotodon
CLI Mastodon Client

# Note
It is currently under heavy development; stable use may not be possible.

# Dependencies
- cURL
- pthread

# Build
## pkgsrc environment
```CFLAGS="-I/usr/pkg/include" LDFLAGS="-L/usr/pkg/lib -Wl,-R/usr/pkg/lib" make```

## OpenBSD
```CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" make```

## Other
```make```

# Options
- ```-mono```  
   - Disable coloring (bold only enabled) (for 1bpp framebuffer)

- ```-unlock```  
   - Show posts with privacy PRIVATE/DIRECT

- ```-noemoji```  
   - Do not use emojis in UI elements such as reblog, favourite, and privacy visibility

- ```-profile <name>```  
   - Use profile ``<name>``

- ```-timeline <public|local|home>```  
   - (WIP) Select timeline to stream

- ```-tllimit <num>```  
   - (WIP) Specify number of toots to fetch via REST API at startup (default is 20)

# How to post
1. Press Enter when the timeline is flowing
2. A prompt ``> `` appears; enter the toot content (``\n`` and ``\\`` can be used)
3. Press Enter to post
- While composing a toot, timeline updates are blocked
- Features such as ``/private`` from previous versions are also available

# Detailed guide
TBW  

# Apparently working environment (24/12/07)
- WSL2 + VSCode Terminal(w/ Sixel)
- WSL2 + Windows Terminal
- OpenBSD/amd64
- NetBSD/i386 10.0 (w/ Sixel)
- NetBSD/evbppc 10.0 (on Nintendo Wii)
- NetBSD/amd64 10.0 (w/ Sixel)
- NetBSD/evbarm 10.0 (w/ Sixel)
- NetBSD/luna68k 10.0 (w/ Sixel)
- NetBSD/vax 10.0 (w/ Sixel)
- NetBSD/mac68k 10.0 (w/ Sixel)
- NetBSD/hp300 10.0 (w/ Sixel)
- NetBSD/sun3 10.0 (w/ Sixel)

# ~~Tested environments (0.1.x-0.3.x)~~
- ~~NetBSD/luna68k + mlterm~~
- ~~NetBSD/x68k + mlterm~~
- ~~NetBSD/sun3 + mlterm~~
- ~~ArchLinux + xfce terminal~~
- ~~WSL1 + mintty(wsl-terminal)~~
- ~~WSL2 + mintty(wsltty)~~
- ~~WSL1 + Windows Terminal~~

# Thanks
- septag : sjson.h (https://github.com/septag/sjson)