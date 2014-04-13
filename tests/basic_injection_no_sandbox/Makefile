CC = clang

all: target payload.dylib

target: target.c
	$(CC) -arch i386 -arch x86_64 $^ -o $@

payload.dylib: payload.c
	$(CC) -arch i386 -arch x86_64 -dynamiclib $^ -o $@

clean:
	rm -f target payload.dylib