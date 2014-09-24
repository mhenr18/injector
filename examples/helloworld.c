#include <stdio.h>

void payload_entry(int argc, char **argv, FILE *in, FILE *out, FILE *err)
{
    fprintf(out, "Hello from payload!\n");

    fprintf(out, "argv: [");
    if (argc > 0) {
        for (int i = 0; i < argc - 1; ++i) {
            fprintf(out, "%s, ", argv[i]);
        }
    
        fprintf(out, "%s]\n", argv[argc - 1]);
    } else {
        fprintf(out, "]\n");
    }
}
