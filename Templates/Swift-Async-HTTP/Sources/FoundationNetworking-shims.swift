{% include "Includes/Header.stencil" %}

import Foundation

#if canImport(FoundationNetworking)

public struct URLRequest {
    init(url: URL) {
        self.url = url
    }
    public var url: URL?
    public var httpMethod: String?
    public var httpBody: Data?
    public var allHTTPHeaderFields: [String : String]?
    public mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        allHTTPHeaderFields?[field] = value
    }
}

public struct HTTPURLResponse {
    
}

#endif
