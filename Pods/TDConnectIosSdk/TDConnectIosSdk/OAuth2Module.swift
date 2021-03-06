/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation
import UIKit
import AeroGearHttp
import JWT
import SafariServices
import WebKit

/**
Notification constants emitted during oauth authorization flow.
*/
public let AGAppLaunchedWithURLNotification = "AGAppLaunchedWithURLNotification"
public let AGAppDidBecomeActiveNotification = "AGAppDidBecomeActiveNotification"
public let AGAuthzErrorDomain = "AGAuthzErrorDomain"

/**
The current state that this module is in.

- AuthorizationStatePendingExternalApproval: the module is waiting external approval.
- AuthorizationStateApproved: the oauth flow has been approved.
- AuthorizationStateUnknown: the oauth flow is in unknown state (e.g. user clicked cancel).
*/
enum AuthorizationState {
    case AuthorizationStatePendingExternalApproval
    case AuthorizationStateApproved
    case AuthorizationStateUnknown
}

public enum OAuth2Error: ErrorType {
    case MissingRefreshToken
    case UnexpectedResponse(String)
    case UnequalStateParameter(String)
}

/**
Parent class of any OAuth2 module implementing generic OAuth2 authorization flow.
*/
public class OAuth2Module: NSObject, AuthzModule, SFSafariViewControllerDelegate {
    
    public let config: Config
    
    var http: Http

    var oauth2Session: OAuth2Session
    var applicationLaunchNotificationObserver: NSObjectProtocol?
    var applicationDidBecomeActiveNotificationObserver: NSObjectProtocol?
    var state: AuthorizationState
    
    /**
    Initialize an OAuth2 module.

    :param: config the configuration object that setups the module.
    :param: session the session that that module will be bound to.
    :param: requestSerializer the actual request serializer to use when performing requests.
    :param: responseSerializer the actual response serializer to use upon receiving a response.

    :returns: the newly initialized OAuth2Module.
    */
    public required init(config: Config, session: OAuth2Session? = nil, requestSerializer: RequestSerializer = HttpRequestSerializer(), responseSerializer: ResponseSerializer = JsonResponseSerializer()) {
        if (config.accountId == nil) {
            config.accountId = "ACCOUNT_FOR_CLIENTID_\(config.clientId)"
        }
        if (session == nil) {
            self.oauth2Session = TrustedPersistantOAuth2Session(accountId: config.accountId!)
        } else {
            self.oauth2Session = session!
        }

        self.config = config
        
        self.http = Http(baseURL: config.baseURL, requestSerializer: requestSerializer, responseSerializer:  responseSerializer)
        self.state = .AuthorizationStateUnknown
    }

    // MARK: Public API - To be overriden if necessary by OAuth2 specific adapter

    /**
    Request an authorization code.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func requestAuthorizationCode(completionHandler: (AnyObject?, NSError?) -> Void) {
        let state = NSUUID().UUIDString
        
        // register with the notification system in order to be notified when the 'authorization' process completes in the
        // external browser, and the oauth code is available so that we can then proceed to request the 'access_token'
        // from the server.
        applicationLaunchNotificationObserver = NSNotificationCenter.defaultCenter().addObserverForName(AGAppLaunchedWithURLNotification, object: nil, queue: nil, usingBlock: { (notification: NSNotification!) -> Void in
            
            let url: NSURL? = (notification.userInfo as! [String: AnyObject])[UIApplicationLaunchOptionsURLKey] as? NSURL
            
            let stateFromRedirectUrl = self.parametersFromQueryString(url?.query)["state"]
            
            guard let _ = stateFromRedirectUrl where stateFromRedirectUrl == state else {
                let error = OAuth2Error.UnequalStateParameter("The state parameter in the redirect url was not the same as the one sent to the auth server,") as NSError
                self.callCompletion(nil, error: error, completionHandler: completionHandler)
                return
            }
            
            self.extractCode(notification, completionHandler: { (accessToken: AnyObject?, error: NSError?) in
                guard let accessToken = accessToken else {
                    self.callCompletion(nil, error: error, completionHandler: completionHandler)
                    return
                }
                
                self.callCompletion(accessToken, error: nil, completionHandler: completionHandler)
            })
            
        })

        // register to receive notification when the application becomes active so we
        // can clear any pending authorization requests which are not completed properly,
        // that is a user switched into the app without Accepting or Cancelling the authorization
        // request in the external browser process.
        applicationDidBecomeActiveNotificationObserver = NSNotificationCenter.defaultCenter().addObserverForName(AGAppDidBecomeActiveNotification, object:nil, queue:nil, usingBlock: { (note: NSNotification!) -> Void in
            // check the state
            if (self.state == .AuthorizationStatePendingExternalApproval) {
                // unregister
                self.stopObserving()
                // ..and update state
                self.state = .AuthorizationStateUnknown;
            }
        })

        // update state to 'Pending'
        self.state = .AuthorizationStatePendingExternalApproval

        // calculate final url
        var url: NSURL
        do {
            url = try OAuth2Module.getAuthUrl(config, http: http, state: state)
        } catch let error as NSError {
            completionHandler(nil, error)
            return
        }
        
        if !self.config.isWebView {
            UIApplication.sharedApplication().openURL(url)
            return
        }
        
        var controller: UIViewController
        if #available(iOS 9.0, *) {
            let safariViewController = SFSafariViewController(URL: url)
            safariViewController.delegate = self
            controller = safariViewController
        } else {
            controller = OAuth2WebViewController()
            (controller as! OAuth2WebViewController).targetURL = url
        }
        
        UIApplication.sharedApplication().keyWindow?.rootViewController?.presentViewController(controller, animated: true, completion: nil)
    }
    
    func callCompletion(success: AnyObject?, error: NSError?, completionHandler: (AnyObject?, NSError?) -> Void) {
        if self.config.isWebView {
            UIApplication.sharedApplication().keyWindow?.rootViewController?.dismissViewControllerAnimated(true, completion: {
                completionHandler(success, error)
            })
        } else {
            completionHandler(success, error)
        }
    }
    
    public class func getAuthUrl(config: Config, http: Http, state: String? = nil) throws -> NSURL {
        let optionalParamsEncoded = config.optionalParams?.keys.reduce("", combine: { (current: String, key: String) -> String in
            return "\(current)&\(key.urlEncode())=\(config.optionalParams![key]!.urlEncode())"
        })
        
        var version = "unknown"
        if let path = NSBundle.mainBundle().pathForResource("Info", ofType: "plist", inDirectory: "Frameworks/TDConnectIosSdk.framework") {
            if let dict = NSDictionary(contentsOfFile: path) {
                let osVersion = NSProcessInfo.processInfo().operatingSystemVersion
                let podVersion = dict["CFBundleShortVersionString"] as! String
                version = "v\(podVersion)_\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            }
        }
        
        var params = "?scope=\(config.scopesEncoded)&redirect_uri=\(config.redirectURL.urlEncode())&client_id=\(config.clientId)&response_type=code&telenordigital_sdk_version=ios_\(version)"
        if let optionalParamsEncoded = optionalParamsEncoded {
            params += optionalParamsEncoded
        }
        
        if let claims = config.claims {
            do {
                try params += OAuth2Module.getClaimsParam(claims)
            } catch {
                throw error
            }
        }
        
        if let state = state {
            params += "&state=\(state)"
        }
        
        guard let computedUrl = http.calculateURL(config.baseURL, url:config.authzEndpoint) else {
            let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "Malformatted URL."])
            throw error
        }
        
        #if swift(>=2.3)
            // this compiles on Xcode 8 / Swift 2.3 / iOS 10
            return NSURL(string:computedUrl.absoluteString! + params)!
        #else
            // this compiles on Xcode 7 / Swift 2.2 / iOS 9
            return NSURL(string:computedUrl.absoluteString + params)!
        #endif
        
    }
    
    public class func getClaimsParam(claims: Set<String>) throws -> String {
        let essentialClaims = claims.reduce([:], combine: { (let current: [String: AnyObject], claim: String) -> [String: AnyObject] in
            var newCurrent = current
            newCurrent[claim] = ["essential": true]
            return newCurrent
        })
        
        let userinfoClaims = [
            "userinfo" : essentialClaims
        ]
        
        var jsonClaims: NSData
        do {
            jsonClaims = try NSJSONSerialization.dataWithJSONObject(userinfoClaims, options: NSJSONWritingOptions())
        } catch let error as NSError {
            print(error)
            throw error
        }
       
        let jsonClaimsString = NSString(data: jsonClaims, encoding: NSUTF8StringEncoding)
        let encodedJson = (jsonClaimsString as! String).urlEncode()
        return "&claims=\(encodedJson)"
    }

    /**
    Request to refresh an access token.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func refreshAccessToken(completionHandler: (AnyObject?, NSError?) -> Void) {
        guard let unwrappedRefreshToken = self.oauth2Session.refreshToken else {
            completionHandler(nil, OAuth2Error.MissingRefreshToken as NSError)
            return
        }
        
        var paramDict: [String: String] = ["refresh_token": unwrappedRefreshToken, "client_id": config.clientId, "grant_type": "refresh_token"]
        if (config.clientSecret != nil) {
            paramDict["client_secret"] = config.clientSecret!
        }
        
        http.request(.POST, path: config.refreshTokenEndpoint!, parameters: paramDict, completionHandler: { (response, error) in
            if (error != nil) {
                if error?.code == 400 {
                    self.oauth2Session.clearTokens()
                }
                
                completionHandler(nil, error)
                return
            }
            
            guard let unwrappedResponse = response as? [String: AnyObject] else {
                completionHandler(nil, OAuth2Error.UnexpectedResponse(response as! String) as NSError)
                return
            }
            
            let accessToken: String = unwrappedResponse["access_token"] as! String
            let expiration = unwrappedResponse["expires_in"] as! NSNumber
            let exp: String = expiration.stringValue
            var refreshToken = unwrappedRefreshToken
            if let newRefreshToken = unwrappedResponse["refresh_token"] as? String {
                refreshToken = newRefreshToken
            }
            
            self.oauth2Session.saveAccessToken(accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: nil, idToken: nil)
            
            completionHandler(unwrappedResponse["access_token"], nil);
        })
    }

    /**
    Exchange an authorization code for an access token.

    :param: code the 'authorization' code to exchange for an access token.
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func exchangeAuthorizationCodeForAccessToken(code: String, completionHandler: (AnyObject?, NSError?) -> Void) {
        var paramDict: [String: String] = ["code": code, "client_id": config.clientId, "redirect_uri": config.redirectURL, "grant_type":"authorization_code"]
        
        if let unwrapped = config.clientSecret {
            paramDict["client_secret"] = unwrapped
        }
        
        http.request(.POST, path: config.accessTokenEndpoint, parameters: paramDict, completionHandler: {(responseObject, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }
            
            guard let unwrappedResponse = responseObject as? [String: AnyObject] else {
                completionHandler(nil, OAuth2Error.UnexpectedResponse(responseObject as! String) as NSError)
                return
            }
            
            let accessToken: String = unwrappedResponse["access_token"] as! String
            let refreshToken: String? = unwrappedResponse["refresh_token"] as? String
            let idToken: String? = unwrappedResponse["id_token"] as? String
            let expiration = unwrappedResponse["expires_in"] as? NSNumber
            let exp: String? = expiration?.stringValue
            // expiration for refresh token is used in Keycloak
            let expirationRefresh = unwrappedResponse["refresh_expires_in"] as? NSNumber
            let expRefresh = expirationRefresh?.stringValue
            
            self.oauth2Session.saveAccessToken(accessToken,
                refreshToken: refreshToken,
                accessTokenExpiration: exp,
                refreshTokenExpiration: expRefresh,
                idToken: idToken)
            completionHandler(accessToken, nil)
        })
    }

    /**
    Gateway to request authorization access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func requestAccess(completionHandler: (AnyObject?, NSError?) -> Void) {
        if (self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()) {
            // we already have a valid access token, nothing more to be done
            completionHandler(self.oauth2Session.accessToken!, nil);
        } else if (self.oauth2Session.refreshToken != nil && self.oauth2Session.refreshTokenIsNotExpired()) {
            // need to refresh token
            self.refreshAccessToken(completionHandler)
        } else {
            // ask for authorization code and once obtained exchange code for access token
            self.requestAuthorizationCode(completionHandler)
        }
    }
    
    /**
    Gateway to provide authentication using the Authorization Code Flow with OpenID Connect.
    
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func login(completionHandler: (AnyObject?, OpenIDClaim?, NSError?) -> Void) {
        
        self.requestAccess { (response:AnyObject?, error:NSError?) -> Void in
            
            if (error != nil) {
                completionHandler(nil, nil, error)
                return
            }

            if let userInfoEndpoint = self.config.userInfoEndpoint {
                let http = Http(baseURL: self.config.baseURL)
                http.authzModule = self
                http.request(.GET, path:userInfoEndpoint, completionHandler: {(responseObject, error) in
                    if (error != nil) {
                        completionHandler(nil, nil, error)
                        return
                    }
                    var openIDClaims: OpenIDClaim?
                    if let unwrappedResponse = responseObject as? [String: AnyObject] {
                        openIDClaims = OpenIDClaim(fromDict: unwrappedResponse)
                    }
                    completionHandler(response, openIDClaims, nil)
                })
            } else {
                completionHandler(nil, nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["OpenID Connect" : "No UserInfo endpoint available in config"]))
                return
            }
            
        }

    }
    
    /**
    Request to revoke access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func revokeAccess(completionHandler: (AnyObject?, NSError?) -> Void) {
        // return if not yet initialized
        if (self.oauth2Session.accessToken == nil) {
            return;
        }
        let paramDict:[String:String] = ["token":self.oauth2Session.accessToken!]

        http.request(.POST, path: config.revokeTokenEndpoint!, parameters: paramDict, completionHandler: { (response, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            self.oauth2Session.clearTokens()
            completionHandler(response, nil)
        })
    }

    /**
    Return any authorization fields.

    :returns:  a dictionary filled with the authorization fields.
    */
    public func authorizationFields() -> [String: String]? {
        if (self.oauth2Session.accessToken == nil) {
            return nil
        } else {
            return ["Authorization":"Bearer \(self.oauth2Session.accessToken!)"]
        }
    }

    /**
    Returns a boolean indicating whether authorization has been granted.

    :returns: true if authorized, false otherwise.
    */
    public func isAuthorized() -> Bool {
        return self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()
    }

    func extractCode(notification: NSNotification, completionHandler: (AnyObject?, NSError?) -> Void) {
        let url: NSURL? = (notification.userInfo as! [String: AnyObject])[UIApplicationLaunchOptionsURLKey] as? NSURL

        // extract the code from the URL
        let code = self.parametersFromQueryString(url?.query)["code"]
        // if exists perform the exchange
        if (code != nil && self.config.isPublicClient) {
            self.exchangeAuthorizationCodeForAccessToken(code!, completionHandler: completionHandler)
            // update state
            state = .AuthorizationStateApproved
        } else if (code != nil && !self.config.isPublicClient) {
            completionHandler(code!, nil)
            state = .AuthorizationStateApproved
        } else {
            let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "User cancelled authorization."])
            completionHandler(nil, error)
        }
        // finally, unregister
        self.stopObserving()
    }

    func parametersFromQueryString(queryString: String?) -> [String: String] {
        var parameters = [String: String]()
        if (queryString != nil) {
            let parameterScanner: NSScanner = NSScanner(string: queryString!)
            var name:NSString? = nil
            var value:NSString? = nil

            while (parameterScanner.atEnd != true) {
                name = nil;
                parameterScanner.scanUpToString("=", intoString: &name)
                parameterScanner.scanString("=", intoString:nil)

                value = nil
                parameterScanner.scanUpToString("&", intoString:&value)
                parameterScanner.scanString("&", intoString:nil)

                if (name != nil && value != nil) {
                    parameters[name!.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding)!] = value!.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding)
                }
            }
        }

        return parameters;
    }
    
    public func getIdTokenPayload() throws -> Payload? {
        guard let signedJwt = oauth2Session.idToken else {
            return nil
        }

        let token = try JWT.decode(signedJwt, algorithm: .None, verify: false, audience: config.clientId, issuer: config.baseURL)
        
        if let failure = validateIdToken(token, expectedIssuer: config.baseURL, expectedAudience: config.clientId) {
            throw failure
        }
        
        return token
    }
    
    public func getIdTokenEncoded() -> String? {
        return oauth2Session.idToken
    }

    deinit {
        self.stopObserving()
    }

    func stopObserving() {
        // clear all observers
        if (applicationLaunchNotificationObserver != nil) {
            NSNotificationCenter.defaultCenter().removeObserver(applicationLaunchNotificationObserver!)
            self.applicationLaunchNotificationObserver = nil;
        }

        if (applicationDidBecomeActiveNotificationObserver != nil) {
            NSNotificationCenter.defaultCenter().removeObserver(applicationDidBecomeActiveNotificationObserver!)
            applicationDidBecomeActiveNotificationObserver = nil
        }
    }
    
    @available(iOS 9.0, *)
    public func safariViewControllerDidFinish(controller: SFSafariViewController) {
        stopObserving()
    }
}
