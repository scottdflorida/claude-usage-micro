#include <signal.h>
#include <unistd.h>

int main(void) {
    (void)signal(SIGHUP, SIG_IGN);
    (void)signal(SIGINT, SIG_IGN);
    (void)signal(SIGTERM, SIG_IGN);
    (void)write(STDOUT_FILENO, "\n$", 2);

    for (;;) {
        (void)pause();
    }
}
