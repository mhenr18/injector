#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void payload_entry(int in, int out, int err)
{
	// we expect "Hello World!", which is 12 chars + a NUL
	const char *expected = "Hello World!";
	char buf[13];
	memset(buf, 0, sizeof(buf));
	int nread = 0;

	while (nread != 12) {
		int n = read(in, buf + nread, 1);

		if (n > 0) {
			nread += n;
		} else {
			// error, bail
			exit(1);
		}
	}

	if (strcmp(expected, buf) != 0) {
		exit(1);
	}
	
	exit(66); // special exit status
}
