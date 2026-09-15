#include <TractandaPlatform.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    char password[4097] = {0};
    char *end = NULL;
    if (argc != 5 || !fgets(password, sizeof(password), stdin)) return 64;
    password[strcspn(password, "\r\n")] = 0;
    errno = 0;
    unsigned long parsed = strtoul(argv[3], &end, 10);
    if (errno || !end || *end || parsed > UINT32_MAX) return 64;
    int expected = atoi(argv[4]);
    int result = tractanda_authenticate_password_broker(argv[1], argv[2], password, (uint32_t)parsed);
    int saved_errno = errno;
    volatile unsigned char *clear = (volatile unsigned char *)password;
    for (size_t index = 0; index < sizeof(password); ++index) clear[index] = 0;
    if (result != expected) {
        fprintf(stderr, "broker-client-fixture: expected %d, received %d (errno %d)\n", expected, result, saved_errno);
        return 1;
    }
    puts("broker-client-fixture: expected result observed");
    return 0;
}
