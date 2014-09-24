CC = clang
CFLAGS = -arch i386 -arch x86_64
LDFLAGS = -framework AppKit -framework CoreFoundation -framework CoreServices -framework Foundation

SRCS = src/main.m src/payload.m src/mach_inject.c
OBJS = $(addsuffix .o,$(SRCS))

all: injector examples

-include $(OBJS:.o=.dep)

src/%.c.o: src/%.c
	$(CC) -MD -MF $(subst .o,.dep,$@) -c $(CFLAGS) $< -o $@

src/%.m.o: src/%.m
	$(CC) -MD -MF $(subst .o,.dep,$@) -c $(CFLAGS) $< -o $@

injector: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJS) -o $@

examples: examples/helloworld.dylib examples/host

examples/helloworld.dylib: examples/helloworld.c
	$(CC) $(CFLAGS) -dynamiclib $^ -o $@

examples/host: examples/host.c
	$(CC) $(CFLAGS) $^ -o $@

clean:
	rm -f $(OBJS) $(subst .o,.dep,$(OBJS)) injector examples/helloworld.dylib examples/host
