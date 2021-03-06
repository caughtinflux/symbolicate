/*

symbolicate.m ... Symbolicate a crash log.
Copyright (C) 2009  KennyTM~ <kennytm@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

*/

#import "symbolicate.h"

#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <notify.h>
#import "RegexKitLite.h"
#include "common.h"

#include "Headers.h"
#include "localSymbols.h"

enum SymbolicationMode {
    SM_CheckingMode,
    SM_ExceptionMode,
    SM_BacktraceMode,
    SM_BinaryImageMode,
};

@interface BacktraceInfo : NSObject {
    @package
        // NSString *binary;
        NSString *start_address;
        unsigned long long address;
}
@end
@implementation BacktraceInfo @end

@interface BinaryInfo : NSObject {
    @package
        // slide = text address - actual address
        unsigned long long address;
        long long slide;
        VMUSymbolOwner *owner;
        VMUMachOHeader *header;
        NSArray *objcArray;
        NSString *path;
        NSUInteger line;
        BOOL encrypted;
        BOOL blamable;
}
@end
@implementation BinaryInfo @end

@interface ObjCInfo : NSObject {
    @package
        unsigned long long impAddr;
        NSString *name;
}
@end
@implementation ObjCInfo @end

static CFComparisonResult CompareObjCInfos(ObjCInfo *a, ObjCInfo *b) {
    return (a->impAddr < b->impAddr) ? kCFCompareLessThan : (a->impAddr > b->impAddr) ? kCFCompareGreaterThan : kCFCompareEqualTo;
}

// NOTE: The code for this function was copied from MachO_File of the Peace project.
static ObjCInfo *extractObjectiveCInfo(VMUMachOHeader *header, NSArray *inputArray, unsigned long long address) {
    ObjCInfo *objcInfo = nil;

    NSMutableArray *array = [inputArray mutableCopy];
    if (array == nil) {
        array = [NSMutableArray array];

        id<VMUMemoryView> mem = (id<VMUMemoryView>)[[header memory] view];
        VMUSegmentLoadCommand *dataSeg = [header segmentNamed:@"__DATA"];
        long long vmdiff_data = [dataSeg fileoff] - [dataSeg vmaddr];
        VMUSegmentLoadCommand *textSeg = [header segmentNamed:@"__TEXT"];
        long long vmdiff_text = [textSeg fileoff] - [textSeg vmaddr];

        VMUSection *clsListSect = [dataSeg sectionNamed:@"__objc_classlist"];

        @try {
            [mem setCursor:[clsListSect offset]];
            unsigned size = (unsigned) [clsListSect size];
            for (unsigned ii = 0; ii < size; ii += 4) {
                unsigned vm_address = [mem uint32];
                unsigned long long old_location = [mem cursor];
                [mem setCursor:vm_address + 16 + vmdiff_data];
                unsigned data_loc = [mem uint32];
                [mem setCursor:data_loc + vmdiff_data];
                unsigned flag = [mem uint32];
                [mem advanceCursor:12];
                [mem setCursor:[mem uint32]+vmdiff_text];

                char class_method = (flag & 1) ? '+' : '-';
                NSString *class_name = [mem stringWithEncoding:NSUTF8StringEncoding];

                [mem setCursor:data_loc + 20 + vmdiff_data];
                unsigned baseMethod_loc = [mem uint32];
                if (baseMethod_loc != 0) {
                    [mem setCursor:baseMethod_loc + 4 + vmdiff_data];
                    unsigned count = [mem uint32];
                    for (unsigned j = 0; j < count; ++j) {
                        ObjCInfo *info = [[ObjCInfo alloc] init];

                        unsigned sel_name_addr = [mem uint32];
                        [mem uint32];
                        info->impAddr = [mem uint32] & ~1;
                        unsigned long long old_loc_2 = [mem cursor];
                        [mem setCursor:sel_name_addr + vmdiff_text];
                        NSString *sel_name = [mem stringWithEncoding:NSUTF8StringEncoding];
                        [mem setCursor:old_loc_2];

                        info->name = [NSString stringWithFormat:@"%c[%@ %@]", class_method, class_name, sel_name];

                        [array addObject:info];
                        [info release];
                    }
                }

                [mem setCursor:old_location];
            }
        } @catch (NSException *exception) {
#if DEBUG
            fprintf(stderr, "Warning: Exception '%s' generated when extracting Objective-C info for %s.\n",
                    [[exception reason] UTF8String], [[header path] UTF8String]);
#endif
        }

        [array sortUsingFunction:(NSInteger (*)(id, id, void *))CompareObjCInfos context:NULL];
    }

    CFIndex count = [array count];
    if (count != 0) {
        ObjCInfo *info = [[ObjCInfo alloc] init];
        info->impAddr = address;

        CFIndex objcMatch = CFArrayBSearchValues((CFArrayRef)array, CFRangeMake(0, count), info, (CFComparatorFunction)CompareObjCInfos, NULL);
        [info release];
        if (objcMatch >= count) {
            objcMatch = count - 1;
        }

        objcInfo = [array objectAtIndex:objcMatch];
        if (objcInfo->impAddr > address) {
            objcInfo = (objcMatch == 0) ? nil : [array objectAtIndex:objcMatch - 1];
        }
    }

    return objcInfo;
}

static NSString *escapeHTML(NSString *x, NSCharacterSet *escSet) {
    // Do not copy unless we're sure the string contains the characters we want to escape.
    if ([x rangeOfCharacterFromSet:escSet].location != NSNotFound) {
        NSMutableString *rx = [NSMutableString stringWithString:x];
        [rx replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [rx length])];
        [rx replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [rx length])];
        [rx replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [rx length])];
        return rx;
    } else {
        return x;
    }
}

NSString *symbolicate(NSString *content, NSDictionary *symbolMaps, unsigned progressStepping) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSArray *inputLines = [content componentsSeparatedByString:@"\n"];
    NSMutableArray *outputLines = [[NSMutableArray alloc] init];
    BOOL shouldNotifyOfProgress = (progressStepping > 0 && progressStepping < 100);

    NSDictionary *whiteListFile = [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"whitelist" ofType:@"plist"]];
    NSSet *filters = [[NSSet alloc] initWithArray:[whiteListFile objectForKey:@"Filters"]];
    NSSet *functionFilters = [[NSSet alloc] initWithArray:[whiteListFile objectForKey:@"FunctionFilters"]];
    NSSet *reverseFilters = [[NSSet alloc] initWithArray:[whiteListFile objectForKey:@"ReverseFunctionFilters"]];
    NSArray *prefixFilters = [whiteListFile objectForKey:@"PrefixFilters"];
    NSArray *signalFilters = [whiteListFile objectForKey:@"SignalFilters"];
    [whiteListFile release];

    enum SymbolicationMode mode = SM_CheckingMode;
    NSMutableArray *extraInfoArray = [[NSMutableArray alloc] init];
    NSMutableDictionary *binaryImages = [[NSMutableDictionary alloc] init];
    BOOL hasLastExceptionBacktrace = NO;
    BOOL isFilteredSignal = YES;

    for (NSString *line in inputLines) {
        // extraInfo:
        //   - true = start of crashing thread.
        //   - false = start of non-crashing thread.
        //   - BacktraceInfo = backtrace info :)
        //   - null = irrelevant.
        id extraInfo = [NSNull null];

        switch (mode) {
            case SM_CheckingMode:
                if ([line hasPrefix:@"Exception Type:"]) {
                    NSUInteger lastCloseParenthesis = [line rangeOfString:@")" options:NSBackwardsSearch].location;
                    if (lastCloseParenthesis != NSNotFound) {
                        NSRange range = NSMakeRange(0, lastCloseParenthesis);
                        NSUInteger lastOpenParenthesis = [line rangeOfString:@"(" options:NSBackwardsSearch range:range].location;
                        if (lastOpenParenthesis < lastCloseParenthesis) {
                            range = NSMakeRange(lastOpenParenthesis + 1, lastCloseParenthesis - lastOpenParenthesis - 1);
                            NSString *signalStr = [line substringWithRange:range];
                            isFilteredSignal = isFilteredSignal && ![signalFilters containsObject:signalStr];
                        }
                    }
                    break;
                } else if ([line hasPrefix:@"Last Exception Backtrace:"]) {
                    hasLastExceptionBacktrace = YES;
                    mode = SM_ExceptionMode;
                    break;
                } else if (![line hasPrefix:@"Thread 0"]) {
                    break;
                } else {
                    // Start of thread 0; fall-through to next case.
                    mode = SM_BacktraceMode;
                }

            case SM_BacktraceMode:
                if ([line isEqualToString:@"Binary Images:"]) {
                    mode = SM_BinaryImageMode;
                } else if ([line length] > 0) {
                    if ([line hasSuffix:@"Crashed:"]) {
                        extraInfo = (id)kCFBooleanTrue;
                    } else if ([line hasSuffix:@":"]) {
                        extraInfo = (id)kCFBooleanFalse;
                    } else {
                        NSArray *array = [line captureComponentsMatchedByRegex:@"^\\d+ +.*\\S\\s+0x([0-9a-f]+) 0x([0-9a-f]+) \\+ \\d+$"];
                        if ([array count] == 3) {
                            NSString *matches[2];
                            [array getObjects:matches range:NSMakeRange(1, 2)];

                            BacktraceInfo *bti = [[[BacktraceInfo alloc] init] autorelease];
                            // bti->binary = matches[0];
                            bti->start_address = matches[1];
                            bti->address = convertHexStringToLongLong([matches[0] UTF8String], [matches[0] length]);
                            extraInfo = bti;
                        }
                    }
                }
                break;

            case SM_ExceptionMode: {
                mode = SM_CheckingMode;

                NSUInteger lastCloseParenthesis = [line rangeOfString:@")" options:NSBackwardsSearch].location;
                if (lastCloseParenthesis != NSNotFound) {
                    NSRange range = NSMakeRange(0, lastCloseParenthesis);
                    NSUInteger firstOpenParenthesis = [line rangeOfString:@"(" options:0 range:range].location;
                    if (firstOpenParenthesis < lastCloseParenthesis) {
                        range = NSMakeRange(firstOpenParenthesis + 1, lastCloseParenthesis - firstOpenParenthesis - 1);
                        NSArray *array = [[line substringWithRange:range] componentsSeparatedByString:@" "];
                        for (NSString *address in array) {
                            BacktraceInfo *bti = [[BacktraceInfo alloc] init];
                            // bti->binary = matches[0];
                            bti->start_address = 0;
                            bti->address = convertHexStringToLongLong([address UTF8String], [address length]);
                            [extraInfoArray addObject:bti];
                            [bti release];

                            [outputLines addObject:[NSNull null]];
                        }
                        continue;
                    }
                }
                break;
            }

            case SM_BinaryImageMode: {
                NSArray *array = [line captureComponentsMatchedByRegex:@"^ *0x([0-9a-f]+) - *[0-9a-fx]+ [ +](.+?) arm\\w*  (?:&lt;[0-9a-f]{32}&gt; )?(.+)$"];
                if ([array count] == 4) {
                    [binaryImages setObject:array forKey:[array objectAtIndex:1]];
                } else {
                    mode = SM_CheckingMode;
                }
                break;
            }
        }

        [outputLines addObject:line];
        [extraInfoArray addObject:extraInfo];
    }

    NSCharacterSet *escSet = [NSCharacterSet characterSetWithCharactersInString:@"<>&"];

    NSUInteger i = 0;
    NSUInteger exceptionStackDepth = 0;
    BOOL isCrashing = NO;
    BOOL hasHeaderFromSharedCacheWithPath = [VMUMemory_File respondsToSelector:@selector(headerFromSharedCacheWithPath:)];
    Class $BinaryInfo = [BinaryInfo class];
    NSUInteger total_lines = [extraInfoArray count];
    int last_percent = 0;

    Ivar _command_ivar = class_getInstanceVariable([VMULoadCommand class], "_command");

    // Prepare array of image start addresses for determining symbols of exception.
    NSArray *imageStartAddresses = nil;
    if (hasLastExceptionBacktrace) {
        NSMutableArray *array = [[NSMutableArray alloc] init];
        for (NSString *key in [binaryImages allKeys]) {
            unsigned long long startAddress = convertHexStringToLongLong([key UTF8String], [key length]);
            NSNumber *number = [[NSNumber alloc] initWithUnsignedLongLong:startAddress];
            [array addObject:number];
            [number release];
        }
        imageStartAddresses = [array sortedArrayUsingSelector:@selector(compare:)];
        [array release];
    }

    for (BacktraceInfo *bti in extraInfoArray) {
         if (shouldNotifyOfProgress) {
             int this_percent = MIN(100, 200 * i / total_lines);
             if (this_percent - last_percent >= progressStepping) {
                 last_percent = this_percent;
                 int token;
                 notify_register_check(PKG_ID".progress", &token);
                 notify_set_state(token, this_percent);
                 notify_post(PKG_ID".progress");
             }
         }

        if (bti == (id)kCFBooleanTrue) {
            isCrashing = YES;
        } else if (bti == (id)kCFBooleanFalse) {
            isCrashing = NO;
        } else if (bti != (id)kCFNull) {
            // Determine start address for this backtrace line.
            if (bti->start_address == 0) {
                for (NSNumber *number in [imageStartAddresses reverseObjectEnumerator]) {
                    unsigned long long startAddress = [number unsignedLongLongValue];
                    if (bti->address > startAddress) {
                        bti->start_address = [NSString stringWithFormat:@"%llx", startAddress];
                        break;
                    }
                }
            }

            // Retrieve info for related binary image.
            BinaryInfo *bi = [binaryImages objectForKey:bti->start_address];
            if (bi != nil) {
                // NOTE: If image has not been processed yet, type will be NSArray.
                if (![bi isKindOfClass:$BinaryInfo]) {
                    // NOTE: Binary images are only processed as needed. Most
                    //       likely only a small number of images were being
                    //       called into at the time of the crash.
                    NSString *matches[3];
                    [(NSArray *)bi getObjects:matches range:NSMakeRange(1, 3)];

                    // Create a BinaryInfo object for the image
                    bi = [[BinaryInfo alloc] init];
                    bi->address = convertHexStringToLongLong([matches[0] UTF8String], [matches[0] length]);
                    bi->path = matches[2];
                    bi->line = 0;
                    bi->blamable = YES;

                    // Get Mach-O header for the image
                    VMUMachOHeader *header = nil;
                    if (hasHeaderFromSharedCacheWithPath) {
                        header = [VMUMemory_File headerFromSharedCacheWithPath:matches[2]];
                    }
                    if (header == nil) {
                        header = [VMUMemory_File headerWithPath:matches[2]];
                    }
                    if (![header isKindOfClass:[VMUMachOHeader class]]) {
                        header = [[VMUHeader extractMachOHeadersFromHeader:header matchingArchitecture:[VMUArchitecture currentArchitecture] considerArchives:NO] lastObject];
                    }
                    if (header != nil) {
                        unsigned long long textStart = [[header segmentNamed:@"__TEXT"] vmaddr];
                        bi->slide = textStart - bi->address;
                        bi->owner = [VMUSymbolExtractor extractSymbolOwnerFromHeader:header];
                        bi->header = header;
                        for (VMULoadCommand *lc in [header loadCommands]) {
                            if ((int)object_getIvar(lc, _command_ivar) == LC_ENCRYPTION_INFO) {
                                bi->encrypted = YES;
                                break;
                            }
                        }
                    }

                    // Determine if binary image should not be blamed.
                    if (hasHeaderFromSharedCacheWithPath && [bi->header isFromSharedCache]) {
                        // Don't blame anything from the shared cache.
                        bi->blamable = NO;
                    } else {
                        // Don't blame white-listed libraries.
                        if ([filters containsObject:bi->path]) {
                            bi->blamable = NO;
                        } else {
                            // Don't blame white-listed folders.
                            for (NSString *prefix in prefixFilters) {
                                if ([bi->path hasPrefix:prefix]) {
                                    bi->blamable = NO;
                                    break;
                                }
                            }
                        }
                    }

                    [binaryImages setObject:bi forKey:bti->start_address];
                    [bi release];
                }

                // Determine if binary image should be blamed.
                if (bi->blamable && (bi->line == 0 || ((bi->line & 0x80000000) && isCrashing))) {
                    // Blame.
                    bi->line = i;
                    // Make it a secondary suspect if it isn't in the crashing thread.
                    if (!isCrashing) {
                        bi->line |= 0x80000000;
                    }
                }

                // If line is from exception, add path and address info.
                id currentLine = [outputLines objectAtIndex:i];
                if (currentLine == (id)kCFNull) {
                    NSString *newLine = [[NSString alloc] initWithFormat:@"%u\t%-30s\t0x%08llx 0x%llx + %llu",
                             exceptionStackDepth, [[bi->path lastPathComponent] UTF8String], bi->address, bti->address, bti->address - bi->address];
                    [outputLines replaceObjectAtIndex:i withObject:newLine];
                    [newLine release];
                    ++exceptionStackDepth;
                }

                // Add source/symbol information to the end of the output line.
                if (bi->header != nil) {
                    NSString *lineComment = nil;
                    unsigned long long address = bti->address + bi->slide;
                    VMUSourceInfo *srcInfo = [bi->owner sourceInfoForAddress:address];
                    if (srcInfo != nil) {
                        // Add source file name and line number.
                        lineComment = [NSString stringWithFormat:@"\t// %@:%u", escapeHTML([srcInfo path], escSet), [srcInfo lineNumber]];
                    } else {
                        NSString *name = nil;
                        unsigned long long offset = 0;

                        // Attempt to add symbol name and hex offset.
                        VMUSymbol *symbol = [bi->owner symbolForAddress:address];
                        if (symbol != nil) {
                            name = [symbol name];
                            if ([name isEqualToString:@"<redacted>"] && hasHeaderFromSharedCacheWithPath) {
                                NSString *localName = nameForLocalSymbol([bi->header address], [symbol addressRange].location);
                                if (localName != nil) {
                                    name = localName;
                                } else {
                                    fprintf(stderr, "Unable to determine name for: %s, 0x%08llx\n", [bi->path UTF8String], [symbol addressRange].location);
                                }
                            }
                            // Attempt to demangle name
                            // NOTE: It seems that Apple's demangler fails for some
                            //       names, so we attempt to do it ourselves.
                            name = demangle(name);

                            // FIXME: Where does this actually belong?
                            if (isCrashing) {
                                // Check if this function should never cause crash (only hang).
                                if ([bi->path isEqualToString:@"/usr/lib/libSystem.B.dylib"] && [functionFilters containsObject:name]) {
                                    isCrashing = NO;
                                }
                            } else if (!isCrashing) {
                                // Check if this function is actually causing crash.
                                if ([bi->path isEqualToString:@"/usr/lib/libSystem.B.dylib"] && [reverseFilters containsObject:name]) {
                                    isCrashing = YES;
                                }
                            }
                            offset = address - [symbol addressRange].location;
                        } else if (NSDictionary *map = [symbolMaps objectForKey:bi->path]) {
                            for (NSNumber *number in [[[map allKeys] sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) {
                                unsigned long long symbolAddress = [number unsignedLongLongValue];
                                if (address > symbolAddress) {
                                    name = demangle([map objectForKey:number]);
                                    offset = address - symbolAddress;
                                    break;
                                }
                            }
                        } else if (!bi->encrypted) {
                            // Try to extract some ObjC info.
                            ObjCInfo *info = extractObjectiveCInfo(bi->header, bi->objcArray, address);
                            if (info != nil) {
                                name = info->name;
                                offset = address - info->impAddr;
                            }
                        }

                        if (name != nil) {
                            lineComment = [NSString stringWithFormat:@"\t// %@ + 0x%llx", escapeHTML(name, escSet), offset];
                        }
                    }
                    if (lineComment != nil) {
                        NSString *oldLine = [outputLines objectAtIndex:i];
                        if (oldLine == (id)kCFNull) {
                            oldLine = @"";
                        }
                        NSString *newLine = [oldLine stringByAppendingString:lineComment];
                        [outputLines replaceObjectAtIndex:i withObject:newLine];
                    }
                }
            }
        }

        ++i;
    }
    [extraInfoArray release];
    [filters release];
    [functionFilters release];
    [reverseFilters release];

    /*
    if (isFilteredSignal) {
        for (NSString *name in binaryImages) {
            BinaryInfo *bi = [binaryImages objectForKey:name];
            if ([bi isKindOfClass:$BinaryInfo] && (bi->line & 0x80000000)) {
                isFilteredSignal = NO;
                break;
            }
        }
    }
    */

    // Write down blame info.
    NSMutableString *blameInfo = [NSMutableString stringWithString:@"<key>blame</key>\n<array>\n"];
    if (isFilteredSignal) {
        for (NSString *name in binaryImages) {
            BinaryInfo *bi = [binaryImages objectForKey:name];
            if ([bi isKindOfClass:$BinaryInfo] && bi->blamable) {
                [blameInfo appendFormat:@"\t<array><string>%@</string><integer>%d</integer></array>\n", escapeHTML(bi->path, escSet), bi->line];
            }
        }
    }
    [blameInfo appendString:@"</array>"];
    [outputLines insertObject:blameInfo atIndex:[outputLines count] - 3];
    [binaryImages release];

    [pool drain];

    [outputLines autorelease];
    return [outputLines componentsJoinedByString:@"\n"];
}

/* vim: set ft=objc ff=unix sw=4 ts=4 tw=80 expandtab: */
