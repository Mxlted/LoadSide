#include "CFileKeychain.h"

/*
 * Apple recommends SecItem, but it cannot create/delete a private file keychain
 * or express its trusted-application ACL. The data-protection keychain is one
 * per user, uses a different entitlement-based access model, and cannot replace
 * a temporary file passed to codesign --keychain. Keep these deprecated calls
 * contained here until Apple offers equivalent lifecycle and ACL APIs.
 *
 * https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
 * https://developer.apple.com/documentation/security/ksecattraccess
 *
 * Only deprecation diagnostics in this compatibility implementation are waived;
 * all other warnings, including deprecations elsewhere, remain enabled.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OSStatus LSFileKeychainCreate(const char *path, UInt32 passwordLength,
                             const void *password, SecKeychainRef *keychain) {
    if (keychain == NULL) return errSecParam;
    *keychain = NULL;
    if (path == NULL || password == NULL || passwordLength == 0) return errSecParam;
    return SecKeychainCreate(path, passwordLength, password, false, NULL, keychain);
}

OSStatus LSFileKeychainUnlock(SecKeychainRef keychain, UInt32 passwordLength,
                             const void *password) {
    /* NULL must never select the user's default keychain or trigger a prompt. */
    if (keychain == NULL || password == NULL || passwordLength == 0) return errSecParam;
    return SecKeychainUnlock(keychain, passwordLength, password, true);
}

OSStatus LSFileKeychainDelete(SecKeychainRef keychain) {
    if (keychain == NULL) return errSecParam;
    return SecKeychainDelete(keychain);
}

static OSStatus createAccess(Boolean includeCodesign, CFStringRef label, SecAccessRef *access) {
    if (access == NULL) return errSecParam;
    *access = NULL;
    SecTrustedApplicationRef caller = NULL;
    SecTrustedApplicationRef codesign = NULL;
    CFArrayRef applications = NULL;
    OSStatus status = SecTrustedApplicationCreateFromPath(NULL, &caller);
    if (status != errSecSuccess) goto cleanup;
    if (includeCodesign) {
        status = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign);
        if (status != errSecSuccess) goto cleanup;
    }
    if (caller == NULL || (includeCodesign && codesign == NULL)) {
        status = errSecInternalComponent;
        goto cleanup;
    }
    const void *trusted[] = {caller, codesign};
    applications = CFArrayCreate(kCFAllocatorDefault, trusted, includeCodesign ? 2 : 1, &kCFTypeArrayCallBacks);
    if (applications == NULL) {
        status = errSecAllocate;
        goto cleanup;
    }
    status = SecAccessCreate(label, applications, access);

cleanup:
    if (applications != NULL) CFRelease(applications);
    if (codesign != NULL) CFRelease(codesign);
    if (caller != NULL) CFRelease(caller);
    return status;
}

OSStatus LSFileKeychainCreateSigningAccess(SecAccessRef *access) {
    return createAccess(true, CFSTR("LoadSide temporary signing key"), access);
}

OSStatus LSFileKeychainCreatePasswordAccess(SecAccessRef *access) {
    return createAccess(false, CFSTR("LoadSide saved signing password"), access);
}

#pragma clang diagnostic pop
