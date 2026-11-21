// Short-lived release helper. Only file paths are accepted as arguments.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSData *p12 = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSString *password = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding];
        if (!p12 || !password.length) return 2;
        SecKeychainRef keychain = NULL;
        SecTrustedApplicationRef codesign = NULL;
        SecAccessRef access = NULL;
        OSStatus status = SecKeychainOpen(argv[2], &keychain);
        if (!status) status = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign);
        if (!status) status = SecAccessCreate(CFSTR("Mailpipe release signing"),
            (__bridge CFArrayRef)@[(__bridge id)codesign], &access);
        if (!status) {
            SecItemImportExportKeyParameters params = {0};
            params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
            params.passphrase = (__bridge CFStringRef)password;
            params.accessRef = access;
            SecExternalFormat format = kSecFormatPKCS12;
            SecExternalItemType type = kSecItemTypeAggregate;
            status = SecItemImport((__bridge CFDataRef)p12, NULL, &format, &type,
                                   0, &params, keychain, NULL);
        }
        if (status) fprintf(stderr, "PKCS12 import failed (OSStatus %d)\n", (int)status);
        return status ? 1 : 0;
    }
}
