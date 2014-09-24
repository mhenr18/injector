injector
========

injector provides a way to inject arbitrary .dylibs into a running process.
Additionally, it provides the injected code with access to the standard I/O
associated with the injector, even if the target process is sandboxed.

injector is known to work on OSX 10.9 and has no 3rd-party dependencies.

Building
--------

Building is done using Make, with no configuration step. Note that there's no
installation step, so the entire build process is performed with a single 
`make` invocation. This will build a universal injector that can inject code
into both i386 and x86_64 binaries.

Usage
-----

Because injector uses task_for_pid(), it will need to be run with root
privledges (i.e using sudo).

Invocation is as follows (likely with a `sudo` preceding):

    injector target_pid payload_path [payload_args...]

where `target_pid` is the PID of the process you're targeting and 
`payload_path` is a path to a .dylib file containing your payload. The .dylib
may be universal (but must at least contain code with the same architecture
as the target).

Your payload .dylib *must* contain a `payload_entry` function, whose signature
is as follows:

    void payload_entry(int argc, char **argv, FILE *in, FILE *out, FILE *err);

This function is called on a new thread upon injection. `in`, `out` and `err`
are files that correspond to the stdin, stdout and stderr of the injector.
Don't close them in your payload.

The injector will run as long as the `out` and `err` files are kept open.

Implementation
--------------

injector is built on Jonathan Rentzsch's mach_inject, which does the heavy
lifting of actually injecting code into other processes. Every time the
injector is used, it generates a session UUID. A piece of bootstrap code
is injected into the target and has the session UUID passed to it. This
bootstrap code runs as a new thread and so does not block the target's
execution. That session UUID is passed through to the payload as its first
argument.

The bootstrap code does the following:

- Allocates thread-local storage.
- Creates a new pthread that we can use to continue bootstrapping.
- Suspends the bootstrap thread and starts the pthread.
- Creates three named fifos in the temporary directory of the process.
  (which have the session UUID in their names).
- Loads the payload .dylib from the same directory (named using the
  session UUID).
- Invokes the payload's payload_entry function.

By using a session UUID, it's possible for the injector binary to watch the
file system event stream and get notified when the payload has created the
fifos. This allows us to find a safe place to copy the payload to.

We can't use a predetermined location and just pass that through with the 
bootstrap injection code, because that location might not be within the
sandbox of the target process. By having the process effectively tell us 
where it can read and write, we sidestep the sandboxing issue.

Once notified of the fifo locations, the injector copies the payload into
the same directory as the fifos and sets up redirection of the standard files
to them.
