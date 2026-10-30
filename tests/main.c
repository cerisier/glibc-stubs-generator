extern int puts(const char *);

/* Normally supplied by glibc's CRT; keep it local as a version script can. */
__attribute__((visibility("hidden"))) const int _IO_stdin_used = 0x20001;

void _start(void) {
    puts("hello");
}
