//
// examples/host.c
// Copyright (c) 2014 Matthew Henry.
// MIT licensed - refer to LICENSE.txt for details.
//
// Literally the world's most useless app. Useful for keeping open in a
// second shell while developing payloads.
//

#include <unistd.h>

int main(int argc, char **argv)
{
    for(;;)
        sleep(1);

    return 0;
}