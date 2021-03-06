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

#import "NSDictionary+ADExtensions.h"
#import "NSString+ADHelperMethods.h"

#import "ADAuthenticationContext+Internal.h"
#import "ADAuthenticationRequest.h"
#import "ADAuthenticationSettings.h"
#import "ADBrokerHelper.h"
#import "ADHelpers.h"
#import "ADPkeyAuthHelper.h"
#import "ADTokenCacheItem+Internal.h"
#import "ADUserIdentifier.h"
#import "ADUserInformation.h"
#import "ADWebAuthController+Internal.h"
#import "ADAuthenticationResult.h"

#if TARGET_OS_IPHONE
#import "ADKeychainTokenCache+Internal.h"
#import "ADBrokerKeyHelper.h"
#import "ADBrokerNotificationManager.h"
#import "ADKeychainUtil.h"
#endif // TARGET_OS_IPHONE

NSString* kAdalResumeDictionaryKey = @"adal-broker-resume-dictionary";

@implementation ADAuthenticationRequest (Broker)

+ (BOOL)validBrokerRedirectUri:(NSString*)url
{
    NSArray* urlTypes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleURLTypes"];
    
    NSURL* redirectURI = [NSURL URLWithString:url];
    
    NSString* scheme = redirectURI.scheme;
    if (!scheme)
    {
        return NO;
    }
    
    NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString* host = [redirectURI host];
    if (![host isEqualToString:bundleId])
    {
        return NO;
    }
    
    for (NSDictionary* urlRole in urlTypes)
    {
        NSArray* urlSchemes = [urlRole objectForKey:@"CFBundleURLSchemes"];
        if ([urlSchemes containsObject:scheme])
        {
            return YES;
        }
    }
    
    return NO;
}

/*!
    Process the broker response and call the completion block, if it is available.
 
    @return YES if the URL was a properly decoded broker response
 */
+ (BOOL)internalHandleBrokerResponse:(NSURL *)response
{
#if TARGET_OS_IPHONE
    __block ADAuthenticationCallback completionBlock = [ADBrokerHelper copyAndClearCompletionBlock];
    
    ADAuthenticationError* error = nil;
    ADAuthenticationResult* result = [self processBrokerResponse:response
                                                           error:&error];
    BOOL fReturn = YES;
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAdalResumeDictionaryKey];
    if (!result)
    {
        result = [ADAuthenticationResult resultFromError:error];
        fReturn = NO;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ADWebAuthDidReceieveResponseFromBroker
                                                        object:nil
                                                      userInfo:@{ @"response" : result }];
    
    // Regardless of whether or not processing the broker response succeeded we always have to call
    // the completion block.
    if (completionBlock)
    {
        completionBlock(result);
    }
    else if (fReturn)
    {
        AD_LOG_ERROR(@"Received broker response without a completionBlock.", AD_FAILED, nil, nil);
        
        [ADWebAuthController setInterruptedBrokerResult:result];
    }
    
    return fReturn;
#else
    (void)response;
    return NO;
#endif // TARGET_OS_IPHONE
}

/*!
    Processes the broker response from the URL
 
    @param  response    The URL the application received from the openURL: handler
    @param  error       (Optional) Any error that occurred trying to process the broker response (note: errors
                        sent in the response itself will be returned as a result, and not populate this parameter)

    @return The result contained in the broker response, nil if the URL could not be processed
 */
+ (ADAuthenticationResult *)processBrokerResponse:(NSURL *)response
                                            error:(ADAuthenticationError * __autoreleasing *)error
{
#if TARGET_OS_IPHONE

    if (!response)
    {
        
        return nil;
    }
    
    NSDictionary* resumeDictionary = [[NSUserDefaults standardUserDefaults] objectForKey:kAdalResumeDictionaryKey];
    if (!resumeDictionary)
    {
        AUTH_ERROR(AD_ERROR_TOKENBROKER_NO_RESUME_STATE, @"No resume state found in NSUserDefaults", nil);
        return nil;
    }
    
    NSUUID* correlationId = [[NSUUID alloc] initWithUUIDString:[resumeDictionary objectForKey:@"correlation_id"]];
    NSString* redirectUri = [resumeDictionary objectForKey:@"redirect_uri"];
    if (!redirectUri)
    {
        AUTH_ERROR(AD_ERROR_TOKENBROKER_BAD_RESUME_STATE, @"Resume state is missing the redirect uri!", correlationId);
        return nil;
    }
    
    // Check to make sure this response is coming from the redirect URI we're expecting.
    if (![[[response absoluteString] lowercaseString] hasPrefix:[redirectUri lowercaseString]])
    {
        AUTH_ERROR(AD_ERROR_TOKENBROKER_MISMATCHED_RESUME_STATE, @"URL not coming from the expected redirect URI!", correlationId);
        return nil;
    }
    
    NSString *qp = [response query];
    //expect to either response or error and description, AND correlation_id AND hash.
    NSDictionary* queryParamsMap = [NSDictionary adURLFormDecode:qp];
    
    if([queryParamsMap valueForKey:OAUTH2_ERROR_DESCRIPTION])
    {
        return [ADAuthenticationResult resultFromBrokerResponse:queryParamsMap];
    }
    
    // Encrypting the broker response should not be a requirement on Mac as there shouldn't be a possibility of the response
    // accidentally going to the wrong app
    NSString* hash = [queryParamsMap valueForKey:BROKER_HASH_KEY];
    if (!hash)
    {
        AUTH_ERROR(AD_ERROR_TOKENBROKER_HASH_MISSING, @"Key hash is missing from the broker response", correlationId);
        return nil;
    }
    
    NSString* encryptedBase64Response = [queryParamsMap valueForKey:BROKER_RESPONSE_KEY];
    NSString* msgVer = [queryParamsMap valueForKey:BROKER_MESSAGE_VERSION];
    NSInteger protocolVersion = 1;
    
    if (msgVer)
    {
        protocolVersion = [msgVer integerValue];
    }
    
    //decrypt response first
    ADBrokerKeyHelper* brokerHelper = [[ADBrokerKeyHelper alloc] init];
    ADAuthenticationError* decryptionError = nil;
    NSData *encryptedResponse = [NSString Base64DecodeData:encryptedBase64Response ];
    NSData* decrypted = [brokerHelper decryptBrokerResponse:encryptedResponse
                                                    version:protocolVersion
                                                      error:&decryptionError];
    if (!decrypted)
    {
        AUTH_ERROR_UNDERLYING(AD_ERROR_TOKENBROKER_DECRYPTION_FAILED, @"Failed to decrypt broker message", decryptionError, correlationId)
        return nil;
    }
    
    
    NSString* decryptedString = [[NSString alloc] initWithData:decrypted encoding:NSUTF8StringEncoding];
    //now compute the hash on the unencrypted data
    NSString* actualHash = [ADPkeyAuthHelper computeThumbprint:decrypted isSha2:YES];
    if(![NSString adSame:hash toString:actualHash])
    {
        AUTH_ERROR(AD_ERROR_TOKENBROKER_RESPONSE_HASH_MISMATCH, @"Decrypted response does not match the hash", correlationId);
        return nil;
    }
    
    // create response from the decrypted payload
    queryParamsMap = [NSDictionary adURLFormDecode:decryptedString];
    [ADHelpers removeNullStringFrom:queryParamsMap];
    ADAuthenticationResult* result = [ADAuthenticationResult resultFromBrokerResponse:queryParamsMap];
    
    NSString* keychainGroup = resumeDictionary[@"keychain_group"];
    if (AD_SUCCEEDED == result.status && keychainGroup)
    {
        ADTokenCacheAccessor* cache = [[ADTokenCacheAccessor alloc] initWithDataSource:[ADKeychainTokenCache keychainCacheForGroup:keychainGroup]
                                                                             authority:result.tokenCacheItem.authority];
        
        [cache updateCacheToResult:result cacheItem:nil refreshToken:nil correlationId:nil];
        
        NSString* userId = [[[result tokenCacheItem] userInformation] userId];
        [ADAuthenticationContext updateResult:result
                                       toUser:[ADUserIdentifier identifierWithId:userId]];
    }
    
    return result;
#else
    (void)response;
    AUTH_ERROR(AD_ERROR_UNEXPECTED, @"broker response parsing not supported on Mac", nil);
    return nil;
#endif
}

- (BOOL)canUseBroker
{
    return _context.credentialsType == AD_CREDENTIALS_AUTO && _context.validateAuthority == YES && [ADBrokerHelper canUseBroker];
}

- (void)callBroker:(ADAuthenticationCallback)completionBlock
{
    CHECK_FOR_NIL(_context.authority);
    CHECK_FOR_NIL(_resource);
    CHECK_FOR_NIL(_clientId);
    CHECK_FOR_NIL(_correlationId);
    
    ADAuthenticationError* error = nil;
    if(![ADAuthenticationRequest validBrokerRedirectUri:_redirectUri])
    {
        error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_TOKENBROKER_INVALID_REDIRECT_URI
                                                       protocolCode:nil
                                                       errorDetails:ADRedirectUriInvalidError
                                                      correlationId:_correlationId];
        completionBlock([ADAuthenticationResult resultFromError:error correlationId:_correlationId]);
        return;
    }
    
    AD_LOG_INFO(@"Invoking broker for authentication", _correlationId, nil);
#if TARGET_OS_IPHONE // Broker Message Encryption
    ADBrokerKeyHelper* brokerHelper = [[ADBrokerKeyHelper alloc] init];
    NSData* key = [brokerHelper getBrokerKey:&error];
    if (!key)
    {
        ADAuthenticationError* adError = [ADAuthenticationError unexpectedInternalError:@"Unable to retrieve broker key." correlationId:_correlationId];
        completionBlock([ADAuthenticationResult resultFromError:adError correlationId:_correlationId]);
        return;
    }
    
    NSString* base64Key = [NSString Base64EncodeData:key];
    NSString* base64UrlKey = [base64Key adUrlFormEncode];
    CHECK_FOR_NIL(base64UrlKey);
#endif // TARGET_OS_IPHONE Broker Message Encryption
    
    NSString* adalVersion = [ADLogger getAdalVersion];
    CHECK_FOR_NIL(adalVersion);
    
    NSDictionary* queryDictionary =
    @{
      @"authority"      : _context.authority,
      @"resource"       : _resource,
      @"client_id"      : _clientId,
      @"redirect_uri"   : _redirectUri,
      @"username_type"  : _identifier ? [_identifier typeAsString] : @"",
      @"username"       : _identifier.userId ? _identifier.userId : @"",
      @"force"          : _promptBehavior == AD_FORCE_PROMPT ? @"YES" : @"NO",
      @"correlation_id" : _correlationId,
#if TARGET_OS_IPHONE // Broker Message Encryption
      @"broker_key"     : base64UrlKey,
#endif // TARGET_OS_IPHONE Broker Message Encryption
      @"client_version" : adalVersion,
      BROKER_MAX_PROTOCOL_VERSION : @"2",
      @"extra_qp"       : _queryParams ? _queryParams : @"",
      };
    
    NSDictionary<NSString *, NSString *>* resumeDictionary = nil;
#if TARGET_OS_IPHONE
    id<ADTokenCacheDataSource> dataSource = [_tokenCache dataSource];
    if (dataSource && [dataSource isKindOfClass:[ADKeychainTokenCache class]])
    {
        NSString* keychainGroup = [(ADKeychainTokenCache*)dataSource sharedGroup];
        NSString* teamId = [ADKeychainUtil keychainTeamId:&error];
        if (!teamId && error)
        {
            completionBlock([ADAuthenticationResult resultFromError:error]);
            return;
        }
        if (teamId && [keychainGroup hasPrefix:teamId])
        {
            keychainGroup = [keychainGroup substringFromIndex:teamId.length + 1];
        }
        resumeDictionary =
        @{
          @"authority"        : _context.authority,
          @"resource"         : _resource,
          @"client_id"        : _clientId,
          @"redirect_uri"     : _redirectUri,
          @"correlation_id"   : _correlationId.UUIDString,
          @"keychain_group"   : keychainGroup
          };

    }
    else
#endif
    {
        resumeDictionary =
        @{
          @"authority"        : _context.authority,
          @"resource"         : _resource,
          @"client_id"        : _clientId,
          @"redirect_uri"     : _redirectUri,
          @"correlation_id"   : _correlationId.UUIDString,
          };
    }
    [[NSUserDefaults standardUserDefaults] setObject:resumeDictionary forKey:kAdalResumeDictionaryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    if ([ADBrokerHelper canUseBroker])
    {
        [ADBrokerHelper invokeBroker:queryDictionary completionHandler:completionBlock];
    }
    else
    {
        [ADBrokerHelper promptBrokerInstall:queryDictionary completionHandler:completionBlock];
    }
}

@end
