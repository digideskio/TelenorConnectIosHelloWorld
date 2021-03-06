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

/**
Configuration object to setup an OAuth2 module
*/
public class Config {
    /**
    Applies the baseURL to the configuration.
    */
    public let baseURL: String

    /**
    Applies the "callback URL" once request token issued.
    */
    public let redirectURL: String

    /**
    Applies the "authorization endpoint" to the request token.
    */
    public var authzEndpoint: String
    
    /**
    Applies the "access token endpoint" to the exchange code for access token.
    */
    public var accessTokenEndpoint: String

    /**
    Endpoint for request to invalidate both accessToken and refreshToken.
    */
    public let revokeTokenEndpoint: String?
    
    /**
    Endpoint for request a refreshToken.
    */
    public let refreshTokenEndpoint: String?
    
    /**
    Endpoint for OpenID Connect to get user information.
    */
    public let userInfoEndpoint: String?
    
    /**
    Boolean to indicate whether OpenID Connect on authorization code grant flow is used.
    */
    public var isOpenIDConnect: Bool
    
    /**
    Applies the various scopes of the authorization.
    */
    public var scopes: [String]
    
    /**
    Returns a string that conatins scopes, separated with spaces and url encoded.
    ["scope1", "scope2"] -> "scope1%20scope2"
    */
    public var scopesEncoded: String {
        get {
            return scopes
                .joinWithSeparator(" ")
                .urlEncode()
        }
    }
    
    /**
    Applies the "client id" obtained with the client registration process.
    */
    public let clientId: String
    
    /**
    Applies the "client secret" obtained with the client registration process.
    */
    public let clientSecret: String?
    
    /**
    Account id is used with AccountManager to store tokens. AccountId is defined by the end-user
    and can be any String. If AccountManager is not used, this field is optional.
    */
    public var accountId: String?
    
    /**
    Optional set of claims that will be formatted as urlencoded json and set as essential.
    Example set: {"openid", "profile", "email", "address", "phone"}
    Intermediate json would be:
     {
     "userinfo":{
       "openid":{"essential":true},
       "profile":{"essential":true},
       "email":{"essential":true},
       "address":{"essential":true},
       "phone":{"essential":true}
       }
     }
    End result will be %7B%22userinfo%22%3A%7B%22openid%22%3A%7B%22essential%22%3Atrue%7D%2C%22profile%22%3A%7B%22essential%22%3Atrue%7D%2C%22email%22%3A%7B%22essential%22%3Atrue%7D%2C%22address%22%3A%7B%22essential%22%3Atrue%7D%2C%22phone%22%3A%7B%22essential%22%3Atrue%7D%7D%7D
    */
    public var claims: Set<String>?
    
    /**
    This dict can be used to set optional query params such as state, prompt, max_age, ui_locales, login_hint and acr_values.
    */
    public var optionalParams: [String: String]?
    
    /**
    Boolean to indicate to either used a webview (if true) or an external browser (by default, false)
    for authorization code grant flow.
    */
    public var isWebView: Bool = false
    
    /**
    Boolean to indicate whether the client is a public client (true) or a confidential client (false).
    A public client will exchange the authorization code for tokens, on successful authentication and authorization.
    A confidential client will not exchange the authorization code but simply return this to the client through the callback, on successful authentication and authorization.
    */
    public let isPublicClient: Bool
    
    public init(base: String, authzEndpoint: String, redirectURL: String, accessTokenEndpoint: String, clientId: String, refreshTokenEndpoint: String? = nil, revokeTokenEndpoint: String? = nil, isOpenIDConnect:Bool = false, userInfoEndpoint: String? = nil, scopes: [String] = [],  clientSecret: String? = nil, accountId: String? = nil, claims: Set<String>? = nil, optionalParams: [String: String]? = nil, isWebView: Bool = false, isPublicClient: Bool = true) {
        self.baseURL = base
        self.authzEndpoint = authzEndpoint
        self.redirectURL = redirectURL
        self.accessTokenEndpoint = accessTokenEndpoint
        self.refreshTokenEndpoint = refreshTokenEndpoint
        self.revokeTokenEndpoint = revokeTokenEndpoint
        self.isOpenIDConnect = isOpenIDConnect ?? false
        self.userInfoEndpoint = userInfoEndpoint
        self.scopes = scopes
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.accountId = accountId
        self.claims = claims
        self.optionalParams = optionalParams
        self.isWebView = isWebView
        self.isPublicClient = isPublicClient
    }
}