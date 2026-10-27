// sftpdrive-sidebar add|remove|has <folder>
// Adds / removes a folder in the Finder sidebar (Favorites). Uses the old LSSharedFileList API,
// which still works from Objective-C (the Swift bindings of it crash).

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static LSSharedFileListItemRef findItem(LSSharedFileListRef list, NSURL *url) {
  UInt32 seed;
  CFArrayRef items = LSSharedFileListCopySnapshot(list, &seed);
  LSSharedFileListItemRef found = NULL;
  for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
    LSSharedFileListItemRef it = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(items, i);
    CFURLRef u = LSSharedFileListItemCopyResolvedURL(it, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
    if (u) {
      if ([[(__bridge NSURL *)u URLByStandardizingPath].path isEqualToString:url.URLByStandardizingPath.path]) {
        found = (LSSharedFileListItemRef)CFRetain(it);
      }
      CFRelease(u);
    }
    if (found) break;
  }
  if (items) CFRelease(items);
  return found;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: sftpdrive-sidebar add|remove|has <folder>\n"); return 2; }
    NSString *cmd = [NSString stringWithUTF8String:argv[1]];
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) return 1;
    LSSharedFileListItemRef existing = findItem(list, url);
    int rc = 0;
    if ([cmd isEqualToString:@"add"]) {
      if (!existing) {
        LSSharedFileListItemRef r = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)url, NULL, NULL);
        if (r) CFRelease(r); else rc = 1;
      }
    } else if ([cmd isEqualToString:@"remove"]) {
      if (existing) rc = LSSharedFileListItemRemove(list, existing) == noErr ? 0 : 1;
    } else if ([cmd isEqualToString:@"has"]) {
      rc = existing ? 0 : 1;
    } else rc = 2;
    if (existing) CFRelease(existing);
    CFRelease(list);
    return rc;
  }
}
