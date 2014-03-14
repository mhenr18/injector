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
// unix file descriptor (which is passed as a CFNumber via the info pointer)
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

// used for fsEventCallback
struct CallbackInfo {
    const char *sessionUUID;
    NSString *payloadPath;
    int signalRecieved;
};

void fsEventCallback(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[])
{
    int i;
    NSString *inPath = nil, *outPath = nil, *errPath = nil;
    NSString *inName, *outName, *errName, *sigName;
    NSString *basePath;
    NSArray *paths = (NSArray *)eventPaths;
    struct CallbackInfo *cbinfo = (struct CallbackInfo *)clientCallBackInfo;
    const char *sessionUUID = cbinfo->sessionUUID;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    inName = [NSString stringWithFormat:@PAYLOAD_IN_FIFO_FMT, sessionUUID];
    outName = [NSString stringWithFormat:@PAYLOAD_OUT_FIFO_FMT, sessionUUID];
    errName = [NSString stringWithFormat:@PAYLOAD_ERR_FIFO_FMT, sessionUUID];
    sigName = [NSString stringWithFormat:@PAYLOAD_SIGNAL_FMT, sessionUUID];
    
    for (i = 0; i < numEvents; ++i) {
        NSString *path = [paths objectAtIndex:i];

        // TODO: handle events where we're forced to scan subdirs/other issues
        
        if ([path hasSuffix:sigName]) {
            basePath = [path stringByDeletingLastPathComponent];

            inPath = [basePath stringByAppendingPathComponent:inName];
            outPath = [basePath stringByAppendingPathComponent:outName];
            errPath = [basePath stringByAppendingPathComponent:errName];
            cbinfo->signalRecieved = 1;
        }

        
        if (inPath && outPath && errPath) {
            // schedule a block to run later as we can't unschedule an fs event
            // stream in the middle of one of its callbacks (hence the const
            // stream ref)
            CFRunLoopPerformBlock(
                CFRunLoopGetCurrent(),
                kCFRunLoopDefaultMode,
            ^{
                NSString *copyPath;
                NSError *err = nil;
                FSEventStreamRef fsEventStream = (FSEventStreamRef)streamRef;
                
                // clean up the fs event stream
                FSEventStreamUnscheduleFromRunLoop(
                    fsEventStream,
                    CFRunLoopGetCurrent(),
                    kCFRunLoopDefaultMode);

                FSEventStreamStop(fsEventStream);
                FSEventStreamInvalidate(fsEventStream);
                FSEventStreamRelease(fsEventStream);
                
                // copy our payload
                copyPath = [NSString stringWithFormat:@"%@/" @PAYLOAD_LIB_FMT,
                    basePath, sessionUUID];

                [fileManager copyItemAtPath:cbinfo->payloadPath 
                                     toPath:copyPath 
                                      error:&err];

                if (err) {
                    fprintf(stderr, "%s: error copying payload\n", 
                        PRODUCT_NAME);
                    fprintf(stderr, "%s: %s\n", PRODUCT_NAME,
                        [[err localizedDescription] UTF8String]);

                    exit(1);
                }

                // and move onto getting a payload connection set up
                setupFIFOs(inPath, outPath, errPath);
            });
            
            break;
        }
    }
}

// Parses the supplied command line args and writes them out to the given
// targetPID and NSString pointers. If parsing succeeds 1 is returned,
// otherwise 0 is returned on failure.
int parseArgs(int argc, char **argv, pid_t *targetPID, NSString **dylibPath)
{
    if (argc < 3) {
        fprintf(stderr, "%1$s: usage %1$s <pid> <dylib_path>\n", PRODUCT_NAME);
        return 0;
    }
    
    // parse our PID and do some error checks to see if we actually tried pid
    // 0 or if we had a junk argument
    *targetPID = atoi(argv[1]);
    if (*targetPID == 0) {
        if (strcmp("0", argv[1]) == 0) {
            fprintf(stderr, "%s: unable to inject into kernel_task (pid 0)\n",
                PRODUCT_NAME);
            return 0;
        } else {
            fprintf(stderr, "%s: invalid pid '%s'\n", PRODUCT_NAME, argv[1]);
            return 0;
        }
    }


    // make sure we've got a dylib to work with
    *dylibPath = [NSString stringWithUTF8String:argv[2]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:*dylibPath]) {
        fprintf(stderr, "%s: no file exists at %s\n", PRODUCT_NAME,
            [*dylibPath UTF8String]);
            
        return 0;
    }

    return 1;
}

// Returns 1 if the process at the given PID has the same binary architecture
// as the current one, or 0 if it doesn't or on error (i.e there's no process
// with the given PID).
int processHasSameArch(pid_t pid)
{
    NSRunningApplication *targetApp = [NSRunningApplication
        runningApplicationWithProcessIdentifier:pid];
    if (!targetApp) {
        fprintf(stderr, "%s: no running application with pid %d\n",
            PRODUCT_NAME, pid);
            
        return 0;
    }
    
    // Ensure the target app has the right arch for the current injector
    #ifdef __x86_64__
    if ([targetApp executableArchitecture] !=
        NSBundleExecutableArchitectureX86_64)
    {
        fprintf(stderr,
            "%s: unable to inject into 32 bit processes - use injector32\n",
            PRODUCT_NAME);
            
        return 0;
    }
    #else
    if ([targetApp executableArchitecture] !=
        NSBundleExecutableArchitectureI386)
    {
        fprintf(stderr,
            "%s: unable to inject into 64 bit processes - use injector64\n",
            PRODUCT_NAME);
            
        return 0;
    }
    #endif

    return 1;
}

int main(int argc, char **argv)
{
@autoreleasepool {
    pid_t targetPID;
    char *payloadParams;
    size_t payloadParamsSize;
    NSString *dylibPath, *copyPath;
    FSEventStreamRef fsEventStream;
    FSEventStreamContext fsContext;
    NSError *error = nil;
    struct CallbackInfo fsCallbackInfo;
    NSArray *fsPaths = @[@"/", @"/var/folders", @"/private"];
    NSString *sessionUUID = [[NSUUID UUID] UUIDString];
    
    if (!parseArgs(argc, argv, &targetPID, &dylibPath)) {
        return 1;
    }

    if (!processHasSameArch(targetPID)) {
        return 1;
    }
    
    // App Sandbox prevents most IPC from functioning. UNIX domain sockets,
    // semaphores, etc are all out of the equation (while it's possible for
    // domain sockets to be located within the target's sandbox, the target 
    // would require a networking entitlement).
    //
    // We can use named FIFOs but they have to be in a location that the
    // sandbox will permit writing to for data to leave the payload. So, we
    // have the payload create the named FIFOs within its sandbox and then
    // create a normal file in the same location that we use as a signal to
    // figure out where a safe common area is.
    //
    // By using a file system event stream, we can get notified when the
    // signal file is created, so that we don't need to try and scan a ton
    // of directories hunting for it.

    fsCallbackInfo.sessionUUID = [sessionUUID UTF8String];
    fsCallbackInfo.payloadPath = dylibPath;
    fsCallbackInfo.signalRecieved = 0;
    
    // Setup our context object and params for use in the file system listener
    // - we zero out the context struct to null out the retain/release cbs and
    // zero out the other fields as required by the API.
    memset(&fsContext, 0, sizeof fsContext);
    fsContext.info = &fsCallbackInfo;
    
    // Establish our FS listener before injecting, so we don't get a race
    // condition.
    fsEventStream = FSEventStreamCreate(kCFAllocatorDefault, fsEventCallback,
        &fsContext, (CFArrayRef)fsPaths, kFSEventStreamEventIdSinceNow, 0.1,
        kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes);
        
    FSEventStreamScheduleWithRunLoop(fsEventStream, CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode);
    FSEventStreamStart(fsEventStream);
    
    // Set up our payload's params (just our session UUID)
    payloadParamsSize = [sessionUUID length] + 1;
    payloadParams = calloc(1, payloadParamsSize);
    memcpy(payloadParams, [sessionUUID UTF8String], [sessionUUID length]);
    
    // We're ready and waiting for the payload so finally inject
    if (mach_inject(payloadEntry, payloadParams,
        (unsigned int)payloadParamsSize, targetPID, 0))
    {
        fprintf(stderr, "%s: failed to inject\n", PRODUCT_NAME);
        return 1;
    }

    // Now wait for our signal file
    SInt32 res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);

    if (!fsCallbackInfo.signalRecieved) {
        // timed out and didn't find the file
        fprintf(stderr, "%s: failed to establish communications (timed out)",
            PRODUCT_NAME);

        // TODO: add a check to see if our target process terminated
    } else {
        // found the file, we're good to run indefinitely now
        CFRunLoopRun();
    }

    return 0;
    
} // end @autoreleasepool
}

