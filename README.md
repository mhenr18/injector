injector
========

injector provides a way to inject arbitrary .dylibs into a running process.
Additionally, it provides the injected code with access to the standard I/O
associated with the injector, even if the target process is sandboxed.

injector is known to work on OSX 10.9.1.

Usage
-----

Because injector uses task_for_pid(), it will need to be run with root
privledges (i.e using sudo).

There are two injector binaries - one for IA-32 and one for x86-64.
You need to use the binary that matches the architecture of the process
being targeted.

Invocation is as follows:

    injector[32/64] <pid> <dylibPath>

where <pid> is the PID of the process you're targeting and <dylibPath>
is a path to a .dylib file containing your payload. The .dylib may be
universal (but must at least contain code with the same architecture
as the target).

Your payload .dylib *must* contain a `payload_main` function, whose signature
is as follows:

    void payload_main(int in, int out, int err);

The `in`, `out` and `err` parameters are file descriptors that correspond to
the standard I/O of the injector binary (i.e, data written to the stdin of the
injector is available from the `in` fd and anything written to `out` or `err`
will end up on the stdout/stderr of the injector).

The `payload_main` function is invoked on a new thread in the target process -
if you need to interact with any UI the first thing you'll want to do is
schedule code on the main run loop. Anything overriden with mach_override can
be done on the new thread as mach_override is atomic.

The injector will run as long as the `out` and `err` files are kept open.

Implementation
--------------

injector is built on Jonathan Rentzsch's mach_inject, which does the heavy
lifting of actually injecting code into other processes. Every time the
injector is used, it generates a session UUID. A piece of bootstrap code
is injected into the target and has the session UUID passed to it. This
bootstrap code runs as a new thread and so does not block the target's
execution.

The bootstrap code does the following:

- Allocates thread-local storage.
- Creates a new pthread that we can use to continue bootstrapping.
- Suspends the initial thread and starts the pthread.
- Creates three named fifos in the temporary directory of the process.
  The fifos have the session UUID in their names.
- Loads the payload .dylib from the same directory (named using the
  session UUID).
- Invokes the payload's payload_main function.


 By using a session UUID, it's possible for the injector binary to watch the
 file system event stream and get notified when the payload has created the
 fifos. This isn't for locking/sync reasons - it's actually to allow us to
 find a safe place to copy the payload to. 

 We can't use a predetermined location and just pass that through with the 
 bootstrap injection code, because that location might not be within the
 sandbox of the target process. By having the process effectively tell us 
 where it can read and write, we sidestep the sandboxing issue.

 Once notified of the fifo locations, the injector copies the payload into
 the same directory as the fifos and sets up redirection of the standard files
 to them.
