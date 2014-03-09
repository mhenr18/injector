CC = clang
CFLAGS = 
LDFLAGS = -framework AppKit -framework CoreFoundation -framework CoreServices -framework Foundation

SRCS = mach_inject.c main.m payload.c

all: injector32 injector64

injector32: $(SRCS)
	$(CC) -m32 $(CFLAGS) $(LDFLAGS) $^ -o $@

injector64: $(SRCS)
	$(CC) -m64 $(CFLAGS) $(LDFLAGS) $^ -o $@

clean:
	rm -f injector32 injector64