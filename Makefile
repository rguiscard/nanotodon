TARGET = nanotodon
OBJS = nanotodon.o sbuf.o squeue.o sixel.o utils.o config.o messages.o Haikutodon.o

# To use both XPG4 strptime(3) and GNU timegm(3)
CFLAGS += -D_GNU_SOURCE

LDLIBS += -lcurl -lpthread -lm

# Use $XDG_CONFIG_HOME or ~/.config dir to save config files
CFLAGS += -DSUPPORT_XDG_BASE_DIR

# EXPERIMENTAL: sixel support
#CFLAGS += -DUSE_SIXEL

# EXPERIMENTAL: webp support
#CFLAGS += -DUSE_WEBP
#LDLIBS += -lwebp

# for pkgsrc 
#CFLAGS += -I/usr/pkg/include
#LDFLAGS += -L/usr/pkg/lib -Wl,-R/usr/pkg/lib

# for FreeBSD and OpenBSD
#CFLAGS += -I/usr/local/include
#LDFLAGS += -L/usr/local/lib

# default
default : $(TARGET)

# rules
$(TARGET) : $(OBJS) Makefile
	$(CC) -o $(TARGET) $(OBJS) $(LDFLAGS) $(LDLIBS)

# commands
clean :
	-rm -f *.o $(TARGET)

# Implicit rules for .c
%.o : %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Explicit rule for Haikutodon.o (compile as C)
Haikutodon.o: Haikutodon.cpp Haikutodon.h
	$(CC) $(CFLAGS) -x c -c $< -o $@