#!/bin/bash

# clean.sh - Injector test cleaning harness
#
# Every test has a Makefile that can be used to clean the test's
# output files. This script acts as a harness to clean all of them.

for I in * ; do
	if [ ! -d $I ]; then
		continue;
	fi

   	echo $I;
	cd $I;
	make clean;
	cd ..;
done
