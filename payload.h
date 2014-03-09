//
// payload.h
// Copyright (c) 2014 Matthew Henry.
// MIT licensed - refer to LICENSE.txt for details.
//

#ifndef injector_payload_h
#define injector_payload_h

#include <stddef.h>
#include <stdlib.h>

#define PAYLOAD_LIB_FMT "payload-%s-lib"
#define PAYLOAD_IN_FIFO_FMT "payload-%s-in"
#define PAYLOAD_OUT_FIFO_FMT "payload-%s-out"
#define PAYLOAD_ERR_FIFO_FMT "payload-%s-err"

void payloadEntry(ptrdiff_t codeOffset, void *paramBlock,
    unsigned int paramSize, void* dummy_pthread_data);

#endif
