#!/bin/bash

# Input injection test
#
# We echo a message into the injector, which has injected a payload
# that will expect that message. If it gets it, it exits the target
# with a successful status.

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
echo -n "Hello World!" | sudo $INJECTOR $TARGETPID payload.dylib;

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