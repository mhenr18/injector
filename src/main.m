//
// src/main.m
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

#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdbool.h>
#include <sys/sysctl.h>
#include "mach_inject.h"
#include "payload.h"

// 1300 300 562
// 40899365

#ifdef __x86_64__
#define INJECTOR_ARCH CPU_TYPE_X86_64
#else
#define INJECTOR_ARCH CPU_TYPE_X86
#endif

struct args {
    pid_t target;
    NSString *payload_path;
    int payload_argc;
    char **payload_argv;
};

struct rwdata {
    int src, dst;
};

// used for fsEventCallback
struct fs_cbinfo {
    const char *session_uuid;
    NSString *payload_path;
    int signal_recieved;
    int in_fifo, out_fifo, err_fifo;
};

__attribute__((noreturn))
static void dief(const char *fmt, ...)
{
    va_list vptr;
    va_start(vptr, fmt);

    fprintf(stderr, "injector: ");
    vfprintf(stderr, fmt, vptr);
    fprintf(stderr, "\n");

    va_end(vptr);

    exit(EXIT_FAILURE);
}

__attribute__((noreturn))
static void usage()
{
    dief("usage: injector pid payload_path [payload_args...]");
}

static struct args parse_args(int argc, char **argv)
{
    struct args args;

    if (argc < 3)
        usage();
    
    // parse our PID and do some error checks to see if we actually tried pid
    // 0 or if we had a junk argument
    args.target = atoi(argv[1]);
    if (args.target == 0) {
        if (strcmp("0", argv[1]) == 0)
            dief("unable to inject into kernel_task (pid 0)");
        else
            dief("invalid pid '%s'", argv[1]);
    }

    // make sure we've got a dylib to work with
    args.payload_path = [NSString stringWithUTF8String:argv[2]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:args.payload_path])
        dief("no file exists at %s", [args.payload_path UTF8String]);

    args.payload_argc = argc - 3;
    args.payload_argv = argv + 3;

    return args;
}

static cpu_type_t process_arch(pid_t pid)
{
    cpu_type_t cpu_type;
    size_t cpu_type_size;
    int mib[CTL_MAXNAME];
    size_t mib_len = CTL_MAXNAME;
    
    if (sysctlnametomib("sysctl.proc_cputype", mib, &mib_len))
        dief("couldn't resolve sysctl mib");

    mib[mib_len] = pid;
    mib_len += 1;
    
    cpu_type_size = sizeof(cpu_type);
    if (sysctl(mib, (u_int)mib_len, &cpu_type, &cpu_type_size, 0, 0))
        dief("couldn't get architecture of PID %d", pid);

    return cpu_type;
}

static const char * arch_name(cpu_type_t arch)
{
    if (arch == CPU_TYPE_X86)
        return "i386";
    else if (arch == CPU_TYPE_X86_64)
        return "x86_64";
    else
        return "???";
}

__attribute__((noreturn))
static void relaunch_with_arch(int argc, char **argv, cpu_type_t arch)
{
    pid_t pid = fork();

    if (!pid) {
        /* child process */
        char **arch_argv = calloc(argc + 4, sizeof(char *));
        arch_argv[0] = "arch";
        arch_argv[1] = "-arch";
        arch_argv[2] = (char *)arch_name(arch);

        for (int i = 0; i < argc; ++i)
            arch_argv[3 + i] = argv[i];
        
        execvp(arch_argv[0], arch_argv);
        dief("failed to exec arch from child process");
    } else if (pid < 0) {
        /* error */
        dief("unable to fork");
    }

    /* parent process */
    int stat_loc;
    waitpid(pid, &stat_loc, 0);
    exit(WEXITSTATUS(stat_loc));
}

static void * rwthread_entry(void *param)
{
    struct rwdata *rwdata = (struct rwdata *)param;
    char buf[512];

    for (;;) {
        ssize_t nread = read(rwdata->src, buf, 512);
        if (nread <= 0) {
            close(rwdata->src);
            close(rwdata->dst);
            return NULL;
        }

        if (write(rwdata->dst, buf, nread) <= 0) {
            close(rwdata->src);
            close(rwdata->dst);
            return NULL;
        }
    }
}





/* Below this point needs cleaning up */





void setupFIFOs(NSString *inPath, NSString *outPath, NSString *errPath,
    struct fs_cbinfo *cbinfo)
{
    // Open up our fifos
    if ((cbinfo->in_fifo = open([inPath UTF8String], O_WRONLY)) < 0)
        dief("couldn't open input fifo");
    
    if ((cbinfo->out_fifo= open([outPath UTF8String], O_RDONLY)) < 0)
        dief("couldn't open output fifo");
    
    if ((cbinfo->err_fifo = open([errPath UTF8String], O_RDONLY)) < 0)
        dief("couldn't open error fifo");
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
    NSString *inPath = nil, *outPath = nil, *errPath = nil;
    NSString *inName, *outName, *errName, *sigName;
    NSString *basePath;
    NSArray *paths = (NSArray *)eventPaths;
    struct fs_cbinfo *cbinfo = (struct fs_cbinfo *)clientCallBackInfo;
    const char *session_uuid = cbinfo->session_uuid;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    inName = [NSString stringWithFormat:@PAYLOAD_IN_FIFO_FMT, session_uuid];
    outName = [NSString stringWithFormat:@PAYLOAD_OUT_FIFO_FMT, session_uuid];
    errName = [NSString stringWithFormat:@PAYLOAD_ERR_FIFO_FMT, session_uuid];
    sigName = [NSString stringWithFormat:@PAYLOAD_SIGNAL_FMT, session_uuid];
    
    for (i = 0; i < numEvents; ++i) {
        NSString *path = [paths objectAtIndex:i];

        // TODO: handle events where we're forced to scan subdirs/other issues
        
        if ([path hasSuffix:sigName]) {
            basePath = [path stringByDeletingLastPathComponent];

            inPath = [basePath stringByAppendingPathComponent:inName];
            outPath = [basePath stringByAppendingPathComponent:outName];
            errPath = [basePath stringByAppendingPathComponent:errName];
            cbinfo->signal_recieved = 1;
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
                    basePath, session_uuid];

                [fileManager copyItemAtPath:cbinfo->payload_path
                                     toPath:copyPath 
                                      error:&err];

                if (err)
                    dief("error copying payload");

                // and move onto getting a payload connection set up
                setupFIFOs(inPath, outPath, errPath, cbinfo);

                // finally, we break out of our run loop
                CFRunLoopStop(CFRunLoopGetCurrent()); 
            });
            
            break;
        }
    }
}

int main(int argc, char **argv)
{
@autoreleasepool {  
    struct args args = parse_args(argc, argv);
    cpu_type_t target_arch = process_arch(args.target);

    /* The injecting binary needs to have the same architecture as the
       target - relaunch if needed to ensure that's the case */
    if (target_arch != INJECTOR_ARCH)
        relaunch_with_arch(argc, argv, target_arch);

    NSString *session_uuid = [[NSUUID UUID] UUIDString];
    struct fs_cbinfo cbinfo;
    cbinfo.session_uuid = [session_uuid UTF8String];
    cbinfo.payload_path = args.payload_path;
    cbinfo.signal_recieved = 0;

    /* Set up some context for the file system listener callbacks */
    FSEventStreamContext fs_context;
    memset(&fs_context, 0, sizeof fs_context);
    fs_context.info = &cbinfo;
    
    /* Ensure we're notified about the fs events by setting up the stream
       before injecting */
    NSArray *fs_paths = @[@"/", @"/var/folders", @"/private"];
    FSEventStreamRef fs_evtstream = FSEventStreamCreate(kCFAllocatorDefault, 
        fsEventCallback, &fs_context, (CFArrayRef)fs_paths, 
        kFSEventStreamEventIdSinceNow, 0.1,
        kFSEventStreamCreateFlagFileEvents
            |kFSEventStreamCreateFlagUseCFTypes);
        
    FSEventStreamScheduleWithRunLoop(fs_evtstream, 
        CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode);
    FSEventStreamStart(fs_evtstream);
    
    /* pass through the arguments to the payload. the first argument is the
       session's uuid which is used to establish named pipes. arguments are
       passed using null terminated strings, with a sequence of two nulls
       terminating the array */
    size_t params_size = [session_uuid length] + 1;
    for (int i = 0; i < args.payload_argc; ++i) {
        params_size += strlen(args.payload_argv[i]) + 1;
    }

    params_size += 2; /* trailing double null to terminate the array */
    char *payload_params = calloc(1, params_size);
    char *p = payload_params;

    memcpy(p, [session_uuid UTF8String], [session_uuid length]);
    p += [session_uuid length] + 1;

    for (int i = 0; i < args.payload_argc; ++i) {
        size_t len = strlen(args.payload_argv[i]);
        memcpy(p, args.payload_argv[i], len);
        p += len + 1;
    }
    
    /* We're ready and waiting for the payload so finally inject */
    if (mach_inject(payloadEntry, payload_params,
            (unsigned int)params_size, args.target, 0))
        dief("failed to inject");

    /* Now spin the run loop for a while so we can listen for the pipe files */
    SInt32 res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);

    if (!cbinfo.signal_recieved)
        dief("failed to establish communications (timed out)");

    /* at this point we just read from our stdin and the our/err fifos and
       shuffle data around (we can't dup2 as that'd close the actual stdin/
       stdout/stderr). we do this by spawning off threads to read and write,
       and join on the out/err ones */
    signal(SIGPIPE, SIG_IGN);
    pthread_t in_thread, out_thread, err_thread;
    struct rwdata indata = { .src = STDIN_FILENO, .dst = cbinfo.in_fifo };
    struct rwdata outdata = { .src = cbinfo.out_fifo, .dst = STDOUT_FILENO };
    struct rwdata errdata = { .src = cbinfo.err_fifo, .dst = STDERR_FILENO };

    pthread_create(&in_thread, NULL, rwthread_entry, &indata);
    pthread_create(&out_thread, NULL, rwthread_entry, &outdata);
    pthread_create(&err_thread, NULL, rwthread_entry, &errdata);

    pthread_detach(in_thread);
    pthread_join(out_thread, NULL);
    pthread_join(err_thread, NULL);
    return 0;
    
} // end @autoreleasepool
}

