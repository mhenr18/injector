#!/bin/bash

# harness.sh - Injector test harness
#
# Each test folder has a test.sh script that expects an architecture
# and injector path. The script exits with a 0 status if the test has
# succeeded and a nonzero status if it fails.
#
# This test harness invokes all of these test scripts and displays
# their results.

echo "Running tests...";
echo "";
echo "note: you may be asked for your password as the injector needs to";
echo "be run using sudo.";
echo "";

NUMFAILED=0;
RESFILE=$1;
PASSFILE=$2;
rm -f $RESFILE $PASSFILE;
touch $RESFILE;

run_test() {
   	$1/test.sh $2 $3;
      RES=$?;

   	printf "$1 ($2) - ";
      printf "$1 ($2) - " >> $RESFILE;

   	if [ $RES -eq 0 ]; then
   		printf "\e[0;32mpassed\e[0m";
         printf "passed" >> $RESFILE;
   	else
   		printf "\e[7;31mFAILED\e[0m";
         printf "FAILED" >> $RESFILE;
         NUMFAILED=`expr $NUMFAILED + 1`;
   	fi

   	printf "\n";
      printf "\n" >> $RESFILE;
}

for I in * ; do
	if [ ! -d $I ]; then
		continue;
	fi

	run_test $I "x86_64" "../out/injector64";
	run_test $I "i386" "../out/injector32";
done

if [ $NUMFAILED -eq 0 ]; then
   touch $PASSFILE;
fi
