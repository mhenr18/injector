#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void payload_main(int in, int out, int err)
{
	const char *msg = "Hello World!\n";
	write(err, msg, strlen(msg));

	exit(0);
}
