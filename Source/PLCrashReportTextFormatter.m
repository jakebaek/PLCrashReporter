/*
 * Authors:
 *  Landon Fuller <landonf@plausiblelabs.com>
 *  Damian Morris <damian@moso.com.au>
 *
 * Copyright (c) 2008-2010 Plausible Labs Cooperative, Inc.
 * Copyright (c) 2010 MOSO Corporation, Pty Ltd.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "CrashReporter/CrashReporter.h"

#import "PLCrashReportTextFormatter.h"
#import <CommonCrypto/CommonDigest.h>


@interface PLCrashReportTextFormatter (PrivateAPI)
NSInteger binaryImageSort(id binary1, id binary2, void *context);
+ (NSString *) formatStackFrame: (PLCrashReportStackFrameInfo *) frameInfo 
                     frameIndex: (NSUInteger) frameIndex
                         report: (PLCrashReport *) report;
@end


/**
 * Formats PLCrashReport data as human-readable text.
 */
@implementation PLCrashReportTextFormatter


/**
 * Formats the provided @a report as human-readable text in the given @a textFormat, and return
 * the formatted result as a string.
 *
 * @param report The report to format.
 * @param textFormat The text format to use.
 *
 * @return Returns the formatted result on success, or nil if an error occurs.
 */
+ (NSString *) stringValueForCrashReport: (PLCrashReport *) report withTextFormat: (PLCrashReportTextFormat) textFormat {
	NSMutableString* text = [NSMutableString string];
	boolean_t lp64 = true; // quiesce GCC uninitialized value warning
    
	/* Header */
	
    /* Map to apple style OS nane */
    NSString *osName;
    switch (report.systemInfo.operatingSystem) {
        case PLCrashReportOperatingSystemMacOSX:
            osName = @"Mac OS X";
            break;
        case PLCrashReportOperatingSystemiPhoneOS:
            osName = @"iPhone OS";
            break;
        case PLCrashReportOperatingSystemiPhoneSimulator:
            osName = @"Mac OS X";
            break;
        default:
            osName = [NSString stringWithFormat: @"Unknown (%d)", report.systemInfo.operatingSystem];
            break;
    }
    
    /* Map to Apple-style code type, and mark whether architecture is LP64 (64-bit) */
    NSString *codeType = nil;
    {
        /* Attempt to derive the code type from the binary images */
        for (PLCrashReportBinaryImageInfo *image in report.images) {
            /* Skip images with no specified type */
            if (image.codeType == nil)
                continue;

            /* Skip unknown encodings */
            if (image.codeType.typeEncoding != PLCrashReportProcessorTypeEncodingMach)
                continue;
            
            switch (image.codeType.type) {
                case CPU_TYPE_ARM:
                    codeType = @"ARM";
                    lp64 = false;
                    break;

                case CPU_TYPE_X86:
                    codeType = @"X86";
                    lp64 = false;
                    break;

                case CPU_TYPE_X86_64:
                    codeType = @"X86-64";
                    lp64 = true;
                    break;

                case CPU_TYPE_POWERPC:
                    codeType = @"PPC";
                    lp64 = false;
                    break;
                    
                default:
                    // Do nothing, handled below.
                    break;
            }

            /* Stop immediately if code type was discovered */
            if (codeType != nil)
                break;
        }

        /* If we were unable to determine the code type, fall back on the legacy architecture value. */
        if (codeType == nil) {
            switch (report.systemInfo.architecture) {
                case PLCrashReportArchitectureARMv6:
                case PLCrashReportArchitectureARMv7:
                    codeType = @"ARM";
                    lp64 = false;
                    break;
                case PLCrashReportArchitectureX86_32:
                    codeType = @"X86";
                    lp64 = false;
                    break;
                case PLCrashReportArchitectureX86_64:
                    codeType = @"X86-64";
                    lp64 = true;
                    break;
                case PLCrashReportArchitecturePPC:
                    codeType = @"PPC";
                    lp64 = false;
                    break;
                default:
                    codeType = [NSString stringWithFormat: @"Unknown (%d)", report.systemInfo.architecture];
                    lp64 = true;
                    break;
            }
        }
    }

    {
        NSString *hardwareModel = @"???";
        if (report.hasMachineInfo && report.machineInfo.modelName != nil)
            hardwareModel = report.machineInfo.modelName;

		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		CFStringRef strRef = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
		NSString *uuidString = [NSString stringWithString:(NSString*)strRef];
		CFRelease(strRef);
		CFRelease(uuidRef);
		[text appendFormat: @"Incident Identifier: %@\n", uuidString];
		
		NSString *reportSummary = [[[[[report threads] valueForKey:@"stackFrames"] valueForKey:@"instructionPointer"] componentsJoinedByString:@","] description];
		const char *string = [reportSummary cStringUsingEncoding:NSUTF8StringEncoding];
		NSData *data = [NSData dataWithBytes:string length:reportSummary.length];
		uint8_t digest[CC_SHA1_DIGEST_LENGTH];
        
		CC_SHA1(data.bytes, data.length, digest);
        
		NSMutableString* output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
		for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
			[output appendFormat:@"%02x", digest[i]];
		[text appendFormat: @"CrashReporter Key: %@\n", output];
        [text appendFormat: @"Hardware Model:      %@\n", hardwareModel];
    }
    
    /* Application and process info */
    {
        NSString *unknownString = @"???";
        
        NSString *processName = unknownString;
        NSString *processId = unknownString;
        NSString *processPath = unknownString;
        NSString *parentProcessName = unknownString;
        NSString *parentProcessId = unknownString;
        
        /* Process information was not available in earlier crash report versions */
        if (report.hasProcessInfo) {
            /* Process Name */
            if (report.processInfo.processName != nil)
                processName = report.processInfo.processName;
            
            /* PID */
            processId = [[NSNumber numberWithUnsignedInteger: report.processInfo.processID] stringValue];
            
            /* Process Path */
            if (report.processInfo.processPath != nil)
                processPath = report.processInfo.processPath;
            
            /* Parent Process Name */
            if (report.processInfo.parentProcessName != nil)
                parentProcessName = report.processInfo.parentProcessName;
            
            /* Parent Process ID */
            parentProcessId = [[NSNumber numberWithUnsignedInteger: report.processInfo.parentProcessID] stringValue];
        }
        
        [text appendFormat: @"Process:         %@ [%@]\n", processName, processId];
        [text appendFormat: @"Path:            %@\n", processPath];
        [text appendFormat: @"Identifier:      %@\n", report.applicationInfo.applicationIdentifier];
        [text appendFormat: @"Version:         %@\n", report.applicationInfo.applicationVersion];
        [text appendFormat: @"Code Type:       %@ (Native)\n", codeType];
        [text appendFormat: @"Parent Process:  %@ [%@]\n", parentProcessName, parentProcessId];
    }
    
    [text appendString: @"\n"];
    
    /* System info */
    {
        NSString *osBuild = @"???";
        if (report.systemInfo.operatingSystemBuild != nil)
            osBuild = report.systemInfo.operatingSystemBuild;
        
        [text appendFormat: @"Date/Time:       %@\n", report.systemInfo.timestamp];
        [text appendFormat: @"OS Version:      %@ %@ (%@)\n", osName, report.systemInfo.operatingSystemVersion, osBuild];
        [text appendFormat: @"Report Version:  104\n"];        
    }

    [text appendString: @"\n"];

    /* Exception code */
    [text appendFormat: @"Exception Type:  %@\n", report.signalInfo.name];
    [text appendFormat: @"Exception Codes: %@ at 0x%" PRIx64 "\n", report.signalInfo.code, report.signalInfo.address];
    
    for (PLCrashReportThreadInfo *thread in report.threads) {
        if (thread.crashed) {
            [text appendFormat: @"Crashed Thread:  %ld\n", (long) thread.threadNumber];
            break;
        }
    }
    
    [text appendString: @"\n"];
    
    /* Uncaught Exception */
    if (report.hasExceptionInfo) {
        [text appendFormat: @"Application Specific Information:\n"];
        [text appendFormat: @"*** Terminating app due to uncaught exception '%@', reason: '%@'\n",
                report.exceptionInfo.exceptionName, report.exceptionInfo.exceptionReason];
        
        [text appendString: @"\n"];
    }
    
    /* Threads */
    PLCrashReportThreadInfo *crashed_thread = nil;
    NSInteger maxThreadNum = 0;
    for (PLCrashReportThreadInfo *thread in report.threads) {
        if (thread.crashed) {
            [text appendFormat: @"Thread %ld Crashed:\n", (long) thread.threadNumber];
            crashed_thread = thread;
        } else {
            [text appendFormat: @"Thread %ld:\n", (long) thread.threadNumber];
        }
        for (NSUInteger frame_idx = 0; frame_idx < [thread.stackFrames count]; frame_idx++) {
            PLCrashReportStackFrameInfo *frameInfo = [thread.stackFrames objectAtIndex: frame_idx];
            [text appendString: [self formatStackFrame: frameInfo frameIndex: frame_idx report: report]];
        }
        [text appendString: @"\n"];

        /* Track the highest thread number */
        maxThreadNum = MAX(maxThreadNum, thread.threadNumber);
    }
    
    /* If an exception stack trace is available, output a pseudo-thread to provide the frame info */
    if (report.exceptionInfo != nil && report.exceptionInfo.stackFrames != nil && [report.exceptionInfo.stackFrames count] > 0) {
        PLCrashReportExceptionInfo *exception = report.exceptionInfo;
        NSInteger threadNum = maxThreadNum + 1;

        /* Create the pseudo-thread header. We use the named thread format to mark this thread */
        [text appendFormat: @"Thread %ld name:  Exception Backtrace\n", threadNum];
        [text appendFormat: @"Thread %ld:\n", (long) threadNum];

        /* Write out the frames */
        for (NSUInteger frame_idx = 0; frame_idx < [exception.stackFrames count]; frame_idx++) {
            PLCrashReportStackFrameInfo *frameInfo = [exception.stackFrames objectAtIndex: frame_idx];
            [text appendString: [self formatStackFrame: frameInfo frameIndex: frame_idx report: report]];
        }
        [text appendString: @"\n"];
    }

    /* Registers */
    if (crashed_thread != nil) {
        [text appendFormat: @"Thread %ld crashed with %@ Thread State:\n", (long) crashed_thread.threadNumber, codeType];
        
        int regColumn = 0;
        for (PLCrashReportRegisterInfo *reg in crashed_thread.registers) {
            NSString *reg_fmt;
            
            /* Use 32-bit or 64-bit fixed width format for the register values */
            if (lp64)
                reg_fmt = @"%6s: 0x%016" PRIx64 " ";
            else
                reg_fmt = @"%6s: 0x%08" PRIx64 " ";
            
            /* Remap register names to match Apple's crash reports */
            NSString *regName = reg.registerName;
            if (report.machineInfo != nil && report.machineInfo.processorInfo.typeEncoding == PLCrashReportProcessorTypeEncodingMach) {
                PLCrashReportProcessorInfo *pinfo = report.machineInfo.processorInfo;
                cpu_type_t arch_type = pinfo.type & ~CPU_ARCH_MASK;

                /* Apple uses 'ip' rather than 'r12' on ARM */
                if (arch_type == CPU_TYPE_ARM && [regName isEqual: @"r12"]) {
                    regName = @"ip";
                }
            }
            [text appendFormat: reg_fmt, [regName UTF8String], reg.registerValue];

            regColumn++;
            if (regColumn == 4) {
                [text appendString: @"\n"];
                regColumn = 0;
            }
        }
        
        if (regColumn != 0)
            [text appendString: @"\n"];
        
        [text appendString: @"\n"];
    }
    
    /* Images. The iPhone crash report format sorts these in ascending order, by the base address */
    [text appendString: @"Binary Images:\n"];
    for (PLCrashReportBinaryImageInfo *imageInfo in [report.images sortedArrayUsingFunction: binaryImageSort context: nil]) {
        NSString *uuid;
        /* Fetch the UUID if it exists */
        if (imageInfo.hasImageUUID)
            uuid = imageInfo.imageUUID;
        else
            uuid = @"???";
        
        /* Determine the architecture string */
        NSString *archName = @"???";
        if (imageInfo.codeType != nil && imageInfo.codeType.typeEncoding == PLCrashReportProcessorTypeEncodingMach) {
            switch (imageInfo.codeType.type) {
                case CPU_TYPE_ARM:
                    /* Apple includes subtype for ARM binaries. */
                    switch (imageInfo.codeType.subtype) {
                        case CPU_SUBTYPE_ARM_V6:
                            archName = @"armv6";
                            break;

                        case CPU_SUBTYPE_ARM_V7:
                            archName = @"armv7";
                            break;
                            
                        default:
                            archName = @"arm-unknown";
                            break;
                    }
                    break;
                    
                case CPU_TYPE_X86:
                    archName = @"i386";
                    break;
                    
                case CPU_TYPE_X86_64:
                    archName = @"x86_64";
                    break;

                case CPU_TYPE_POWERPC:
                    archName = @"powerpc";
                    break;

                default:
                    // Use the default archName value (initialized above).
                    break;
            }
        }

        /* Determine if this is the main executable */
        NSString *binaryDesignator = @" ";
        if ([imageInfo.imageName isEqual: report.processInfo.processPath])
            binaryDesignator = @"+";
        
        /* base_address - terminating_address [designator]file_name arch <uuid> file_path */
        NSString *fmt = nil;
        if (lp64) {
            fmt = @"%18#" PRIx64 " - %18#" PRIx64 " %@%@ %@  <%@> %@\n";
        } else {
            fmt = @"%10#" PRIx64 " - %10#" PRIx64 " %@%@ %@  <%@> %@\n";
        }

        [text appendFormat: fmt,
                            imageInfo.imageBaseAddress,
                            imageInfo.imageBaseAddress + (MAX(1, imageInfo.imageSize) - 1), // The Apple format uses an inclusive range
                            binaryDesignator,
                            [imageInfo.imageName lastPathComponent],
                            archName,
                            uuid,
                            imageInfo.imageName];
    }
    

    return text;
}

/**
 * Initialize with the request string encoding and output format.
 *
 * @param textFormat Format to use for the generated text crash report.
 * @param stringEncoding Encoding to use when writing to the output stream.
 */
- (id) initWithTextFormat: (PLCrashReportTextFormat) textFormat stringEncoding: (NSStringEncoding) stringEncoding {
    if ((self = [super init]) == nil)
        return nil;
    
    _textFormat = textFormat;
    _stringEncoding = stringEncoding;

    return self;
}

// from PLCrashReportFormatter protocol
- (NSData *) formatReport: (PLCrashReport *) report error: (NSError **) outError {
    NSString *text = [PLCrashReportTextFormatter stringValueForCrashReport: report withTextFormat: _textFormat];
    return [text dataUsingEncoding: _stringEncoding allowLossyConversion: YES];
}
		 
@end


@implementation PLCrashReportTextFormatter (PrivateMethods)

/**
 * Format a stack frame for display in a thread backtrace.
 *
 * @param frameInfo The stack frame to format
 * @param frameIndex The frame's index
 * @param report The report from which this frame was acquired.
 *
 * @return Returns a formatted frame line.
 */
+ (NSString *) formatStackFrame: (PLCrashReportStackFrameInfo *) frameInfo 
                     frameIndex: (NSUInteger) frameIndex
                         report: (PLCrashReport *) report
{
    /* Base image address containing instrumention pointer, offset of the IP from that base
     * address, and the associated image name */
    uint64_t baseAddress = 0x0;
    uint64_t pcOffset = 0x0;
    NSString *imageName = @"\?\?\?";
    
    PLCrashReportBinaryImageInfo *imageInfo = [report imageForAddress: frameInfo.instructionPointer];
    if (imageInfo != nil) {
        imageName = [imageInfo.imageName lastPathComponent];
        baseAddress = imageInfo.imageBaseAddress;
        pcOffset = frameInfo.instructionPointer - imageInfo.imageBaseAddress;
    }
    
    return [NSString stringWithFormat: @"%-4ld%-36s0x%08" PRIx64 " 0x%" PRIx64 " + %" PRId64 "\n", 
            (long) frameIndex,
            [imageName UTF8String],
            frameInfo.instructionPointer, 
            baseAddress, 
            pcOffset];
}

/**
 * Sort PLCrashReportBinaryImageInfo instances by their starting address.
 */
NSInteger binaryImageSort(id binary1, id binary2, void *context) {
    uint64_t addr1 = [binary1 imageBaseAddress];
    uint64_t addr2 = [binary2 imageBaseAddress];
    
    if (addr1 < addr2)
        return NSOrderedAscending;
    else if (addr1 > addr2)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

@end
