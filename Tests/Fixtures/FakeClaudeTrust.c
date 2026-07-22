#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

int main(void) {
    char input[256];
    int input_byte;
    struct termios original_terminal;
    struct termios raw_terminal;

    (void)setvbuf(stdout, NULL, _IONBF, 0);
    (void)puts("Permission Required: Accessing workspace:");
    (void)puts("Enter y/n:");
    if (fgets(input, sizeof(input), stdin) == NULL || input[0] != 'y') {
        return 2;
    }

    (void)puts("$");
    if (fgets(input, sizeof(input), stdin) == NULL || strstr(input, "/usage") == NULL) {
        return 3;
    }

    // Deliberately avoids Claude's current headings and percentage wording.
    // The Expect helper is transport only; schema interpretation belongs in Swift.
    (void)puts("SESSION LIMIT\nUsed: 10%");
    (void)puts("Weekly limit - all models\n80% remaining");
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

    // Both delays exceed the helper's one-second quiet-capture timeout. They
    // verify that prompt and exit waits restore the normal twenty-second timeout.
    (void)sleep(2);
    (void)puts("\n$");
    if (fgets(input, sizeof(input), stdin) == NULL || strstr(input, "/exit") == NULL) {
        return 5;
    }
    (void)sleep(2);
    return 0;
}
