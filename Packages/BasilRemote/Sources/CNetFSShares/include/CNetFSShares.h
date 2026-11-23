#ifndef CNETFSSHARES_H
#define CNETFSSHARES_H

#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

/// Lists the shares of an SMB server through macOS's own SMB plugin for NetFS
/// (/System/Library/Filesystems/NetFSPlugins/smb.bundle, the interface in NetFS/NetFSPlugin.h),
/// in this process: no smbutil, and the password never reaches a command line.
///
/// `url` is smb://user:password@host[:port] (user and password percent-encoded) or
/// smb://host for a guest login with `guest` true. On success returns 0 and sets `shares` to a
/// dictionary from share name to its NetFS properties (the caller releases it); otherwise
/// returns an errno value (EAUTH: the server refused the login), a NetFS error, or
/// `BasilSMBPluginMissing`.
#define BasilSMBPluginMissing (-99999)

int BasilSMBListShares(CFURLRef url, bool guest, CFDictionaryRef _Nullable * _Nonnull shares);

CF_ASSUME_NONNULL_END

#endif
