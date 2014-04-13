CC = clang
CFLAGS = -g
LDFLAGS = -framework AppKit -framework CoreFoundation -framework CoreServices -framework Foundation

SRCS = main.m payload.m mach_inject/mach_inject/mach_inject.c
OBJS32 = $(addprefix obj/, $(addsuffix .32.o,$(SRCS)))
OBJS64 = $(addprefix obj/, $(addsuffix .64.o,$(SRCS)))

all: out/all_tests_passed

no-tests: out/injector32 out/injector64

out/all_tests_passed: out/injector32 out/injector64
	@cd tests && ./harness.sh ../out/testresults.txt ../out/all_tests_passed

tests: out/injector32 out/injector64
	@cd tests && ./harness.sh ../out/testresults.txt ../out/all_tests_passed

-include $(OBJS32:.32.o=.32.dep)
-include $(OBJS64:.64.o=.64.dep)

obj/%.32.o: %
	@mkdir -p $(dir $@)
	$(CC) -MD -MF $(subst .o,.dep,$@) -c -m32 $(CFLAGS) $< -o $@

obj/%.64.o: %
	@mkdir -p $(dir $@)
	$(CC) -MD -MF $(subst .o,.dep,$@) -c -m64 $(CFLAGS) $< -o $@

out/injector32: $(OBJS32)
	@mkdir -p $(dir $@)
	$(CC) -m32 $(LDFLAGS) $(OBJS32) -o $@

out/injector64: $(OBJS64)
	@mkdir -p $(dir $@)
	$(CC) -m64 $(LDFLAGS) $(OBJS64) -o $@

clean:
	rm -rf obj out
	@cd tests && ./clean.sh