#ifndef LOADSIDE_CFILEKEYCHAIN_H
#define LOADSIDE_CFILEKEYCHAIN_H

#include <Security/Security.h>

/*
 * Compatibility boundary for the file-based keychain operations that SecItem
 * cannot replace. Signing identities need a disposable keychain that codesign
 * can open by path; remembered passwords retain the existing caller-only ACL.
 * No function changes the default keychain or its search list.
 *
 * Create functions return retained objects through their output parameters.
 * Delete removes the keychain from disk; it does not release the reference.
 */
OSStatus LSFileKeychainCreate(const char * _Nonnull path, UInt32 passwordLength,
                             const void * _Nonnull password,
                             SecKeychainRef _Nullable * _Nonnull CF_RETURNS_RETAINED keychain);
OSStatus LSFileKeychainUnlock(SecKeychainRef _Nonnull keychain, UInt32 passwordLength,
                             const void * _Nonnull password);
OSStatus LSFileKeychainDelete(SecKeychainRef _Nonnull keychain);

/* Trust only the caller and /usr/bin/codesign for a temporary signing key. */
OSStatus LSFileKeychainCreateSigningAccess(SecAccessRef _Nullable * _Nonnull CF_RETURNS_RETAINED access);

/* Trust only the caller for explicitly remembered generic-password items. */
OSStatus LSFileKeychainCreatePasswordAccess(SecAccessRef _Nullable * _Nonnull CF_RETURNS_RETAINED access);

#endif
