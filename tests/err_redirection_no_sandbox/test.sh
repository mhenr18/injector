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

rm -f output.txt;

# ensure our test binaries are built
make > /dev/null;

# launch our target
arch -arch $ARCH ./target &
TARGETPID=$!;

# now inject our payload and get its output
sudo $INJECTOR $TARGETPID payload.dylib 2> output.txt;

# check whether the injector worked
if [ $? -ne 0 ]; then
	kill -9 $TARGETPID;
	exit 1;
fi

# The injector's done so we can be certain that the target
# has exited - no cleanup is needed

# check whether we got our expected output
diff expected_output.txt output.txt > /dev/null;

if [ $? -eq 0 ]; then
	exit 0;
else
	exit 1;
fi