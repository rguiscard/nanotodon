TARGET = nanotodon
OBJS = nanotodon.o sbuf.o squeue.o image.o utils.o

# To use both XPG4 strptime(3) and GNU timegm(3)
CFLAGS += -D_GNU_SOURCE

LDLIBS += -lcurl -lpthread -lm

# EXPERIMENTAL: kitty graphics support for image attachments
#CFLAGS += -DUSE_KITTY

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
