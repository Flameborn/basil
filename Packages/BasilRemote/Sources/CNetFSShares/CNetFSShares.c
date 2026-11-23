#include "CNetFSShares.h"
#include <NetFS/NetFSPlugin.h>
#include <errno.h>

static NetFSMountInterface_V1 **smbInterface(void) {
    static NetFSMountInterface_V1 **interface = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFURLRef bundle = CFURLCreateWithFileSystemPath(NULL,
            CFSTR("/System/Library/Filesystems/NetFSPlugins/smb.bundle"), kCFURLPOSIXPathStyle, true);
        CFPlugInRef plugin = CFPlugInCreate(NULL, bundle);
        CFRelease(bundle);
        if (plugin == NULL) return;
        CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kNetFSTypeID, plugin);
        if (factories == NULL || CFArrayGetCount(factories) == 0) {
            if (factories) CFRelease(factories);
            return;
        }
        CFUUIDRef factory = CFArrayGetValueAtIndex(factories, 0);
        IUnknownVTbl **unknown = (IUnknownVTbl **)CFPlugInInstanceCreate(NULL, factory, kNetFSTypeID);
        CFRelease(factories);
        if (unknown == NULL) return;
        LPVOID found = NULL;
        (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kfs_NetFSMountInterfaceID_V1), &found);
        (*unknown)->Release(unknown);
        // Kept for the life of the process, like the plugin itself.
        interface = (NetFSMountInterface_V1 **)found;
    });
    return interface;
}

int BasilSMBListShares(CFURLRef url, bool guest, CFDictionaryRef *shares) {
    *shares = NULL;
    NetFSMountInterface_V1 **smb = smbInterface();
    if (smb == NULL) return BasilSMBPluginMissing;
    void *session = NULL;
    int status = (*smb)->CreateSessionRef(&session);
    if (status != 0) return status;
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(options, kNAUIOptionKey, kNAUIOptionNoUI);
    if (guest) CFDictionarySetValue(options, kNetFSUseGuestKey, kCFBooleanTrue);
    CFDictionaryRef info = NULL;
    status = (*smb)->OpenSession(url, session, options, &info);
    CFRelease(options);
    if (info) CFRelease(info);
    if (status == 0) status = (*smb)->EnumerateShares(session, NULL, shares);
    (*smb)->CloseSession(session);
    return status;
}
