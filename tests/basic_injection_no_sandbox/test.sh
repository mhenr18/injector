#!/bin/bash

# Basic Injection test
#
# Tests for basic injection functionality and nothing more.
# The test binary sleeps for 10 seconds and then exits with status 0.
# When injected, the payload exits with status 66. We simply wait
# on the target to see what exit status we have to verify injection.

realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}";
}

ARCH=$1;
INJECTOR=$(realpath $2); # normalise path to injector before switching dir

# ensure we're in the test dir
cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )";

# ensure our test binaries are built
make > /dev/null;

# launch our target
arch -arch $ARCH ./target &
TARGETPID=$!;

# now inject our payload
sudo $INJECTOR $TARGETPID payload.dylib;

# check whether the injector worked
if [ $? -ne 0 ]; then
	kill -9 $TARGETPID;
	exit 1;
fi

# and wait on the target to get its exit status
wait $TARGETPID;

# if we have status 66, we worked.
if [ $? -eq 66 ]; then
	exit 0;
else
	exit 1;
fi