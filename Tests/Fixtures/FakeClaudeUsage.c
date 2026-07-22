#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

// Renders a complete, parser-recognizable /usage screen whose reset times track
// the wall clock, so the Expect helper and Swift parser can be composed end to end.
int main(void) {
    char input[256];
    char session_reset[64];
    char weekly_reset[64];
    int input_byte;
    struct termios original_terminal;
    struct termios raw_terminal;
    time_t now = time(NULL);
    time_t session_time = now + 2 * 60 * 60;
    time_t weekly_time = now + 3 * 24 * 60 * 60;
    struct tm session_parts;
    struct tm weekly_parts;

    (void)setvbuf(stdout, NULL, _IONBF, 0);
    if (gmtime_r(&session_time, &session_parts) == NULL || gmtime_r(&weekly_time, &weekly_parts) == NULL) {
        return 70;
    }
    if (strftime(session_reset, sizeof(session_reset), "Resets %I:%M %p (UTC)", &session_parts) == 0
        || strftime(weekly_reset, sizeof(weekly_reset), "Resets %A at %I:%M %p (UTC)", &weekly_parts) == 0) {
        return 70;
    }

    (void)write(STDOUT_FILENO, "\n$", 2);
    if (fgets(input, sizeof(input), stdin) == NULL || strstr(input, "/usage") == NULL) {
        return 3;
    }

    (void)puts("Current session");
    (void)puts("37% used");
    (void)puts(session_reset);
    (void)puts("");
    (void)puts("Current week (all models)");
    (void)puts("25% used");
    (void)puts(weekly_reset);
    (void)puts("");
    (void)puts("Current week (Fable)");
    (void)puts("56% used");

    if (tcgetattr(STDIN_FILENO, &original_terminal) != 0) {
        return 4;
    }
    raw_terminal = original_terminal;
    raw_terminal.c_lflag &= (tcflag_t) ~(ICANON | ECHO);
    raw_terminal.c_cc[VMIN] = 1;
    raw_terminal.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw_terminal) != 0) {
        return 4;
    }
    input_byte = getchar();
    if (tcsetattr(STDIN_FILENO, TCSANOW, &original_terminal) != 0) {
        return 4;
    }
    if (input_byte != '\033') {
        return 4;
    }

    (void)write(STDOUT_FILENO, "\n$", 2);
    if (fgets(input, sizeof(input), stdin) == NULL || strstr(input, "/exit") == NULL) {
        return 5;
    }
    return 0;
}
