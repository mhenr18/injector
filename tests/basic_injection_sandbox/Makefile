CC = clang
TARGET = target.app/Contents/MacOS/basic_injection_sandbox_target

all: $(TARGET) payload.dylib

$(TARGET): target.c
	$(CC) -arch i386 -arch x86_64 $^ -o $@
	codesign --force --sign - --entitlements target.entitlements target.app

payload.dylib: payload.c
	$(CC) -arch i386 -arch x86_64 -dynamiclib $^ -o $@

clean:
	rm -rf $(TARGET) payload.dylib target.app/Contents/_CodeSignature
