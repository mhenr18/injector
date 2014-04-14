injector
========

injector provides a way to inject arbitrary .dylibs into a running process.
Additionally, it provides the injected code with access to the standard I/O
associated with the injector, even if the target process is sandboxed.

injector is known to work on OSX 10.9.1+.

Cloning
-------

injector uses git submodules to reference the underlying mach_inject library.
Because of this, you'll need to make sure you clone these as well when cloning
this repository.

With newer versions of git, you can do this by just passing the `--recursive`
flag to `git clone`. For example,

    git clone --recursive https://github.com/mhenr18/injector.git

will clone the repository + the submodule. Older versions of git can accomplish
the same task by using:

    git clone https://github.com/mhenr18/injector.git
	cd injector
	git submodule update --init --recursive

Aside from submodules, injector has no other dependencies.

Building
--------

Building is done using Make, with no configuration step. Note that there's no
installation step, so the entire build process is performed with a single 
`make` invocation. This will build injectors for both i386 and x86_64 and leave
them in the `out` directory.

It will also run some test scripts. Unfortunately, because injector requires
elevated permissions to function, these scripts are currently forced to use
sudo to run the injector binaries. This means that you'll be prompted for your
password during these tests.

If you don't want to run these tests, you can use `make no-tests` to build.

Usage
-----

Because injector uses task_for_pid(), it will need to be run with root
privledges (i.e using sudo).

There are two injector binaries - one for i386 and one for x86_64.
You need to use the binary that matches the architecture of the process
being targeted.

Invocation is as follows (likely with a `sudo` preceding):

    injector[32|64] <pid> <dylibPath>

where `<pid>` is the PID of the process you're targeting and `<dylibPath>`
is a path to a .dylib file containing your payload. The .dylib may be
universal (but must at least contain code with the same architecture
as the target).

Your payload .dylib *must* contain a `payload_entry` function, whose signature
is as follows:

    void payload_entry(int in, int out, int err);

This function is called on a new thread upon injection. `in`, `out` and `err`
are fds that correspond to the stdin, stdout and stderr of the injector. Note
that managing them is the role of the payload - they aren't closed if needed
when the entry point returns.

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
