// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ADNTLMUIPrompt.h"
#import "ADCredentialCollectionController.h"

@interface ADNTLMUIPrompt ()
{
    
}

@end

@implementation ADNTLMUIPrompt

+ (void)presentPrompt:(void (^)(NSString * username, NSString * password))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert new];
        
        [alert setMessageText:NSLocalizedString(@"Enter your credentials", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Login", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        
        ADCredentialCollectionController* view = [ADCredentialCollectionController new];
        SAFE_ARC_AUTORELEASE(view);
        [view.usernameLabel setStringValue:NSLocalizedString(@"Username", nil)];
        [view.passwordLabel setStringValue:NSLocalizedString(@"Password", nil)];
        [alert setAccessoryView:view.customView];
        
        [alert beginSheetModalForWindow:[NSApp keyWindow] completionHandler:^(NSModalResponse returnCode)
         {
             if (returnCode == 1000)
             {
                 NSString* username = [view.usernameField stringValue];
                 NSString* password = [view.passwordField stringValue];
                 
                 completionHandler(username, password);
             }
             else
             {
                 completionHandler(nil, nil);
             }
         }];
    });
}

@end
