// SecKeychainCreate with a private path avoids the security CLI's search-list update.
#include <Security/Security.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    SecKeychainRef keychain = NULL;
    const char password[] = "synthetic fixture only";
    OSStatus status = SecKeychainCreate(argv[1], sizeof(password) - 1, password,
                                        false, NULL, &keychain);
    if (status) fprintf(stderr, "Fixture keychain creation failed (OSStatus %d)\n", (int)status);
    return status ? 1 : 0;
}
