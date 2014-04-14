CC = clang
TARGET = target.app/Contents/MacOS/basic_injection_sandbox_target

all: $(TARGET) payload.dylib

$(TARGET): target.c
	mkdir target.app target.app/Contents target.app/Contents/MacOS target.app/Contents/Resources
	cp Info.plist target.app/Contents/Info.plist
	$(CC) -arch i386 -arch x86_64 $^ -o $@
	codesign --force --sign - --entitlements target.entitlements target.app

payload.dylib: payload.c
	$(CC) -arch i386 -arch x86_64 -dynamiclib $^ -o $@

clean:
	rm -rf payload.dylib target.app
