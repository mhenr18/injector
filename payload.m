//
// payload.m
// Copyright (c) 2014 Matthew Henry.
// MIT licensed - refer to LICENSE.txt for details.
//
// The code contained in this file is compiled to run in one binary, but
// executes as a payload in a target binary. To avoid standard library/runtime
// conflicts, we don't use C++ or (much) ObjC here. For the ObjC we do use, we
// have to explicitly send messages as objc_msgSend needs relocation!
//
// TODO: Test to see if our use of ObjC makes it impossible to inject into
// binaries that don't link against Foundation.framework
//

#import <Foundation/Foundation.h>
#import <objc/message.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_init.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "payload.h"

// Macro used for getting function pointers to relocated code. The relocated
// function pointer is declared as fcn_impl, where fcn is the original function
// name.
#define RELOCATE(offset, ret, fcn, ...) ret (*fcn ## _impl)(__VA_ARGS__) = \
    (ret (*)(__VA_ARGS__))((char*)fcn + offset)

// private API (fortunately we're not going for the App Store!)
extern void __pthread_set_self(char *);

// params used for payloadThreadEntry
struct ThreadParams {
    char *sessionUUID;
    ptrdiff_t codeOffset;
};

void* payloadThreadEntry(void* param)
{
    // TODO: don't use fixed size buffers
    #define BUFSIZE 512
    char inPath[BUFSIZE], outPath[BUFSIZE], errPath[BUFSIZE], libPath[BUFSIZE], sigPath[BUFSIZE];
    char *base, *expanded;
    int inFIFO, outFIFO, errFIFO;
    size_t len;
    struct ThreadParams* params = (struct ThreadParams*)param;
    void (*dylib_entry)(int, int, int);
    void *dylib_handle;
    NSString *tempDirPath;
    FILE *sigFile;
    
    // we still need to relocate here (fortunately our dylib doesn't have to!)
    RELOCATE(params->codeOffset, void*, dlopen, const char *, int);
    RELOCATE(params->codeOffset, void*, dlsym, void *, const char *);
    RELOCATE(params->codeOffset, int, printf, const char *restrict, ...);
    RELOCATE(params->codeOffset, int, sprintf, char *restrict,
        const char *restrict, ...);
    RELOCATE(params->codeOffset, int, open, const char *, int, ...);
    RELOCATE(params->codeOffset, void, perror, const char *);
    RELOCATE(params->codeOffset, void *, memset, void *, int, size_t);
    RELOCATE(params->codeOffset, int, mkfifo, const char *, mode_t);
    RELOCATE(params->codeOffset, NSString *, NSTemporaryDirectory, void);
    RELOCATE(params->codeOffset, id, objc_msgSend, id, SEL, ...);
    RELOCATE(params->codeOffset, void *, malloc, size_t);
    RELOCATE(params->codeOffset, size_t, strlen, const char *);
    RELOCATE(params->codeOffset, char *, strcpy, char *, const char *);
    RELOCATE(params->codeOffset, FILE *, fopen, const char *, const char *);
    RELOCATE(params->codeOffset, void, fclose, FILE *);

    tempDirPath = NSTemporaryDirectory_impl();
    if (!tempDirPath) {
        perror_impl("can't get temp dir path\n");
        return NULL;
    }

    // obscene hackery to call UTF8String on our path, as the compiler
    // will generate objc_msgSend calls that won't be relocated
    base = (char *)objc_msgSend_impl(tempDirPath, @selector(UTF8String));

    // make sure we don't have a trailing backslash
    len = strlen_impl(base);
    expanded = malloc_impl(len + 1);
    strcpy_impl(expanded, base);
    if (expanded[len - 1] == '/') {
        expanded[len - 1] = 0;
    }
    
    // In literally any other case I'd convert this into a function call.
    // But, relocating everything sucks hard + there's a gazillion params used.
    
    // in fifo
    memset_impl(inPath, 0, BUFSIZE);
    sprintf_impl(inPath, "%s/" PAYLOAD_IN_FIFO_FMT, expanded,
        params->sessionUUID);
        
    if (mkfifo_impl(inPath, 0777)) {
        perror_impl("couldn't make in fifo\n");
        return NULL;
    }
    
    // out fifo
    memset_impl(outPath, 0, BUFSIZE);
    sprintf_impl(outPath, "%s/" PAYLOAD_OUT_FIFO_FMT, expanded,
        params->sessionUUID);
        
    if (mkfifo_impl(outPath, 0777)) {
        perror_impl("couldn't make out fifo\n");
        return NULL;
    }
    
    // err fifo
    memset_impl(errPath, 0, BUFSIZE);
    sprintf_impl(errPath, "%s/" PAYLOAD_ERR_FIFO_FMT, expanded,
        params->sessionUUID);
        
    if (mkfifo_impl(errPath, 0777)) {
        perror_impl("couldn't make err fifo\n");
        return NULL;
    }


    // signal file to tell the injector our fifos exist (handles cases
    // where the fifos haven't shown up in the FS event stream)
    memset_impl(sigPath, 0, BUFSIZE);
    sprintf_impl(sigPath, "%s/" PAYLOAD_SIGNAL_FMT, expanded,
        params->sessionUUID);
        
    sigFile = fopen_impl(sigPath, "w");
    fclose_impl(sigFile);
    


    // we open our fifos after creating them all as the injector will look for
    // the signal file before opening any on its end
    if ((inFIFO = open_impl(inPath, O_RDONLY)) < 0) {
        perror_impl("couldn't open in fifo\n");
        return NULL;
    }

    if ((outFIFO = open_impl(outPath, O_WRONLY)) < 0) {
        perror_impl("couldn't open out fifo\n");
        return NULL;
    }
    
    if ((errFIFO = open_impl(errPath, O_WRONLY)) < 0) {
        perror_impl("couldn't open err fifo\n");
        return NULL;
    }

    // Now we can load our payload and run it
    memset_impl(libPath, 0, BUFSIZE);
    sprintf_impl(libPath, "%s/" PAYLOAD_LIB_FMT, expanded,
        params->sessionUUID);

    dylib_handle = dlopen_impl(libPath, RTLD_NOW);
    if (!dylib_handle) {
        printf_impl("couldn't open payload\n");
        return NULL;
    }

    dylib_entry = (void (*)(int, int, int))
        dlsym_impl(dylib_handle, "payload_main");
    
    if (!dylib_entry) {
        printf_impl("no entry point\n");
        return NULL;
    }
    
    dylib_entry(inFIFO, outFIFO, errFIFO);
    return NULL;
}

void payloadEntry(ptrdiff_t codeOffset, void *paramBlock,
    unsigned int paramSize, void* dummy_pthread_data)
{
    // In this function, we're in the rawest of raw states. We have no
    // thread-local storage, our function addresses are wrong, we're not
    // allowed to return and we can't take a lock because we're not in a thread
    // as recognized by pthreads.
    //
    // All we do here is a minimal bootstrap to get into a new thread that will
    // at least allow us to take a lock. Once we're at that point we'll finally
    // be able to set up a socket and actually load in the specified payload.
    //
    // NOTE: It's an *extremely* appealing idea to actually copy the injector
    // binary into a globally visible location and load it into the target
    // process via dlopen, which would allow us to just continue bootstrap in
    // there without needing to relocate function pointers.
    
    char *sessionUUID;
    int policy;
    struct sched_param sched;
    pthread_attr_t attr;
    pthread_t thread;
    struct ThreadParams params;
    
    RELOCATE(codeOffset, int, pthread_attr_init, pthread_attr_t *);
    RELOCATE(codeOffset, void, __pthread_set_self, char *);
    RELOCATE(codeOffset, int, pthread_attr_getschedpolicy,
        const pthread_attr_t * __restrict, int * __restrict);
    RELOCATE(codeOffset, int, pthread_attr_setdetachstate, pthread_attr_t *,
        int);
    RELOCATE(codeOffset, int, pthread_attr_setinheritsched, pthread_attr_t *,
        int);
    RELOCATE(codeOffset, int, sched_get_priority_max, int);
    RELOCATE(codeOffset, int, pthread_attr_setschedparam,
        pthread_attr_t * __restrict, const struct sched_param * __restrict);
    RELOCATE(codeOffset, int, pthread_create, pthread_t * __restrict,
        const pthread_attr_t * __restrict, void *(*)(void *),
        void * __restrict);
    RELOCATE(codeOffset, int, pthread_attr_destroy, pthread_attr_t *);
    RELOCATE(codeOffset, mach_port_t, mach_thread_self, void);
    RELOCATE(codeOffset, kern_return_t, thread_suspend, thread_act_t);
    RELOCATE(codeOffset, size_t, strlen, const char *);
    
    // We allocate our thread-local storage using the memory provided. This
    // isn't documented but is done in mach_inject_bundle. From inspecting the
    // mach_inject source it's clear that there's enough room in this buffer
    // for bootstrap purposes.
    __pthread_set_self_impl((char*)dummy_pthread_data);

    // Now that we've got a slightly saner state let's create a new "normal"
    // thread that we can load our dylib in - this thread is too raw to use for
    // anything as we can't take a lock.
    pthread_attr_init_impl(&attr);
    pthread_attr_getschedpolicy_impl(&attr, &policy);
    pthread_attr_setdetachstate_impl(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setinheritsched_impl(&attr, PTHREAD_EXPLICIT_SCHED);
    sched.sched_priority = sched_get_priority_max_impl(policy);
    pthread_attr_setschedparam_impl(&attr, &sched);
    
    sessionUUID = (char *)paramBlock;
    
    params.sessionUUID = sessionUUID;
    params.codeOffset = codeOffset;
    
    pthread_create_impl(&thread, &attr,
        (void* (*)(void*))((long)payloadThreadEntry + codeOffset), &params);
    pthread_attr_destroy_impl(&attr);
    
    // we can't return, so just suspend ourselves (we'd be returning to
    // 0xDEADBEEF!)
    // TODO: try and clean ourselves up as much as possible
    thread_suspend_impl(mach_thread_self_impl());
}
