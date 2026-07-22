#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int write_child_pid(const char *path, pid_t child_pid) {
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        return -1;
    }
    int write_failed = fprintf(file, "%d", child_pid) < 0;
    int close_failed = fclose(file) != 0;
    if (write_failed || close_failed) {
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        return 64;
    }

    pid_t child_pid = fork();
    if (child_pid < 0) {
        return 70;
    }
    if (child_pid == 0) {
        (void)close(STDIN_FILENO);
        (void)close(STDOUT_FILENO);
        (void)close(STDERR_FILENO);
        (void)signal(SIGHUP, SIG_IGN);
        (void)signal(SIGINT, SIG_IGN);
        (void)signal(SIGTERM, SIG_IGN);
        for (;;) {
            (void)pause();
        }
    }

    if (write_child_pid(argv[1], child_pid) != 0) {
        return 70;
    }
    if (strcmp(argv[2], "abnormal") == 0) {
        return 17;
    }
    if (strcmp(argv[2], "output-limit") == 0) {
        char output[4096];
        (void)memset(output, 'x', sizeof(output));
        ssize_t bytes_written = write(STDOUT_FILENO, output, sizeof(output));
        return bytes_written == (ssize_t)sizeof(output) ? 0 : 71;
    }
    return 64;
}
