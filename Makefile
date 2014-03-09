CC = clang
CFLAGS = -g
LDFLAGS = -framework AppKit -framework CoreFoundation -framework CoreServices -framework Foundation

SRCS = mach_inject.c main.m payload.m

all: injector32 injector64

injector32: $(SRCS)
	$(CC) -m32 $(CFLAGS) $(LDFLAGS) $^ -o $@

injector64: $(SRCS)
	$(CC) -m64 $(CFLAGS) $(LDFLAGS) $^ -o $@

clean:
	rm -f injector32 injector64
	rm -rf injector32.dSYM injector64.dSYM