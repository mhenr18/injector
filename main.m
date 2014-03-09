//
// main.m
// Copyright (c) 2014 Matthew Henry.
// MIT licensed - refer to LICENSE.txt for details.
//
// Note: Because this source is compiled both as 32 and 64 bit, we can't use
// ARC as it's not available when targeting the legacy 32 bit runtime.
//

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdbool.h>
#include "mach_inject.h"
#include "payload.h"

#ifdef __x86_64__
#define PRODUCT_NAME "injector64"
#else
#define PRODUCT_NAME "injector32"
#endif

// CFFileDescriptor callback for forwarding data written to f out to a
// unix file descriptor (which is passed as the info pointer)
void forwardingCallback(CFFileDescriptorRef f, CFOptionFlags callBackTypes,
    void *info)
{
    int src = CFFileDescriptorGetNativeDescriptor(f);
    int dest;
    ssize_t len;
    char buf[128];
    
    CFNumberGetValue((CFNumberRef)info, kCFNumberIntType, &dest);
    
    // TODO: error-check syscalls
    for (;;) {
        len = read(src, buf, 128);
        
        if (len > 0) {
            write(dest, buf, len);
            
            if (len != 128) {
                break;
            }
        } else {
            break;
        }
    }
    
    // callbacks are one-shot so we have to keep asking for them
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
}

// helpers for use with CF context structs
void *retain(void *info)
{
    return (void *)CFRetain((CFTypeRef)info);
}

void release(void *info)
{
    CFRelease((CFTypeRef)info);
}

// Adds a CFFileDescriptor to the main run loop to forward data from the
// `from` file descriptor to the `to` file descriptor.
void addForwardingDescriptor(int from, int to)
{
    CFFileDescriptorRef fdRef;
    CFRunLoopSourceRef rlSrc;
    CFFileDescriptorContext context;
    memset(&context, 0, sizeof context);
    context.retain = retain;
    context.release = release;
    context.info = (void *)CFNumberCreate(kCFAllocatorDefault,
        kCFNumberIntType, &to);
    
    fdRef = CFFileDescriptorCreate(kCFAllocatorDefault, from, true,
        forwardingCallback, &context);
    CFFileDescriptorEnableCallBacks(fdRef, kCFFileDescriptorReadCallBack);
    rlSrc = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, fdRef, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
}

// Adds CFFileDescriptors to the main run loop to handle forwarding data from:
//   - stdin to the named fifo at inPath
//   - the named fifo at outPath to stdout
//   - the named fifo at errPath to stderr
//
// TODO: revise to use dup2 - I kept mucking up and SIGPIPE'ing the target
// TODO: implement proper failure cases for when we can't open the fifos
void setupFIFOs(NSString *inPath, NSString *outPath, NSString *errPath)
{
    int inFIFO, outFIFO, errFIFO;
    
    // Open up our fifos
    if ((inFIFO = open([inPath UTF8String], O_WRONLY)) < 0) {
        fprintf(stderr, "%s: couldn't open input fifo\n", PRODUCT_NAME);
        return;
    }
    
    if ((outFIFO = open([outPath UTF8String], O_RDONLY)) < 0) {
        fprintf(stderr, "%s: couldn't open output fifo\n", PRODUCT_NAME);
        return;
    }
    
    if ((errFIFO = open([errPath UTF8String], O_RDONLY)) < 0) {
        fprintf(stderr, "%s: couldn't open error fifo\n", PRODUCT_NAME);
        return;
    }
    
    // and setup our forwarding descriptors
    addForwardingDescriptor(STDIN_FILENO, inFIFO);
    addForwardingDescriptor(outFIFO, STDOUT_FILENO);
    addForwardingDescriptor(errFIFO, STDERR_FILENO);
}

void fsEventCallback(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[])
{
    int i;
    NSArray *paths = (NSArray *)eventPaths;
    NSString *inPath = nil, *outPath = nil, *errPath = nil;
    NSString *inName, *outName, *errName;
    const char *sessionUUID = [(NSString *)clientCallBackInfo UTF8String];
    
    inName = [NSString stringWithFormat:@PAYLOAD_IN_FIFO_FMT, sessionUUID];
    outName = [NSString stringWithFormat:@PAYLOAD_OUT_FIFO_FMT, sessionUUID];
    errName = [NSString stringWithFormat:@PAYLOAD_ERR_FIFO_FMT, sessionUUID];
    
    for (i = 0; i < numEvents; ++i) {
        NSString *path = [paths objectAtIndex:i];
        
        if ([path hasSuffix:inName]) {
            inPath = path;
        } else if ([path hasSuffix:outName]) {
            outPath = path;
        } else if ([path hasSuffix:errName]) {
            errPath = path;
        }
        
        if (inPath && outPath && errPath) {
            // schedule a block to run later as we can't unschedule an fs event
            // stream in the middle of one of its callbacks (hence the const
            // stream ref)
            CFRunLoopPerformBlock(
                CFRunLoopGetCurrent(),
                kCFRunLoopDefaultMode,
            ^{
                // safe to cast - not in the stream's callback anymore
                FSEventStreamRef fsEventStream = (FSEventStreamRef)streamRef;
                
                // clean up the fs event stream
                FSEventStreamUnscheduleFromRunLoop(
                    fsEventStream,
                    CFRunLoopGetCurrent(),
                    kCFRunLoopDefaultMode);

                FSEventStreamStop(fsEventStream);
                FSEventStreamInvalidate(fsEventStream);
                FSEventStreamRelease(fsEventStream);
                
                // and move onto getting a payload connection set up
                setupFIFOs(inPath, outPath, errPath);
            });
            
            break;
        }
    }
}

int main(int argc, char **argv)
{
@autoreleasepool {
    // TODO: Prove that it's safe (i.e find docs) to use NSRunningApplication
    // without having a current NSApplication instance. (or just fire up an
    // NSApplication)
    
    pid_t targetPID;
    char *payloadParams;
    size_t payloadParamsSize;
    NSString *dylibPath, *copyPath;
    NSRunningApplication *targetApp;
    FSEventStreamRef fsEventStream;
    FSEventStreamContext fsContext;
    NSError *error = nil;
    NSArray *fsPaths = @[@"/"];
    NSString *sessionUUID = [[NSUUID UUID] UUIDString];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    if (argc < 3) {
        fprintf(stderr, "%1$s: usage %1$s <pid> <dylib_path>\n", PRODUCT_NAME);
        return 1;
    }
    
    // TODO: validate pid (although mach_inject doesn't inject PID 0 so atoi's
    // failure case is tolerable for now)
    targetPID = atoi(argv[1]);
    dylibPath = [NSString stringWithUTF8String:argv[2]];
    if (![fileManager fileExistsAtPath:dylibPath]) {
        fprintf(stderr, "%s: no file exists at %s\n", PRODUCT_NAME,
            [dylibPath UTF8String]);
            
        return 1;
    }
    
    // We assume that our target is sandboxed, making it unable to read from
    // most places. We copy the dylib to /usr/lib, which is one of the
    // "blessed" directories that sandboxed apps may read from. Because we need
    // root privleges to inject, we'll be fine to copy there.
    copyPath = [NSString stringWithFormat:@"/usr/lib/payload-%@", sessionUUID];
    [fileManager copyItemAtPath:dylibPath toPath:copyPath error:&error];
    if (error) {
        fprintf(stderr,
            "%s: error copying file to globally visible location (/usr/lib)\n",
            PRODUCT_NAME);
            
        fprintf(stderr, "%s: %s\n", PRODUCT_NAME,
            [[error localizedDescription] UTF8String]);
        return 1;
    }
    
    targetApp = [NSRunningApplication
        runningApplicationWithProcessIdentifier:targetPID];
    if (!targetApp) {
        fprintf(stderr, "%s: no running application with pid %d\n",
            PRODUCT_NAME, targetPID);
            
        return 1;
    }
    
    // Ensure the target app has the right arch for the current injector
    #ifdef __x86_64__
    if ([targetApp executableArchitecture] !=
        NSBundleExecutableArchitectureX86_64)
    {
        fprintf(stderr,
            "%s: unable to inject into 32 bit processes - use injector32\n",
            PRODUCT_NAME);
            
        return 1;
    }
    #else
    if ([targetApp executableArchitecture] !=
        NSBundleExecutableArchitectureI386)
    {
        fprintf(stderr,
            "%s: unable to inject into 64 bit processes - use injector64\n",
            PRODUCT_NAME);
            
        return 1;
    }
    #endif
    
    // App Sandbox prevents most IPC from functioning. UNIX domain sockets,
    // semaphores, etc are all out of the equation (while it's possible for
    // domain sockets to be located in a common place, the process requires a
    // networking entitlement).
    //
    // We can use named FIFOs but they have to be in a location that the
    // sandbox will permit writing to for data to leave the payload. So, we
    // have the payload create the named FIFOs within its sandbox and listen
    // for the file creation events to figure out where they are.
    
    memset(&fsContext, 0, sizeof fsContext);
    fsContext.info = sessionUUID;
    
    // Establish our FS listener before injecting, so we don't get a race
    // condition.
    fsEventStream = FSEventStreamCreate(kCFAllocatorDefault, fsEventCallback,
        &fsContext, (CFArrayRef)fsPaths, kFSEventStreamEventIdSinceNow, 0.1,
        kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes);
        
    FSEventStreamScheduleWithRunLoop(fsEventStream, CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode);
    FSEventStreamStart(fsEventStream);
    
    // Set up our payload's params (which are effectively memcpy'd to our
    // target process, so we can't just pass a struct with pointers to strings)
    payloadParamsSize = [sessionUUID length] + [copyPath length] + 2;
    payloadParams = calloc(1, payloadParamsSize);
    memcpy(payloadParams, [sessionUUID UTF8String], [sessionUUID length]);
    memcpy(payloadParams + [sessionUUID length] + 1, [copyPath UTF8String],
        [copyPath length]);
    
    // We're ready and waiting for the payload so finally inject
    if (mach_inject(payloadEntry, payloadParams,
        (unsigned int)payloadParamsSize, targetPID, 0))
    {
        fprintf(stderr, "%s: failed to inject\n", PRODUCT_NAME);
        return 1;
    }
    
    // TODO: add a timeout so we don't hang forever when something breaks
    CFRunLoopRun();
    return 0;
    
} // end @autoreleasepool
}

