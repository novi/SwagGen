{% include "Includes/Header.stencil" %}

import Foundation
import AsyncHTTPClient
import NIO
import NIOHTTP1
#if canImport(FoundationNetworking) && !NO_USE_FOUNDATION_NETWORKING
import FoundationNetworking
#endif

/// Manages and sends APIRequests
public class APIClient {

    public static var `default` = APIClient(baseURL: {% if options.baseURL %}"{{ options.baseURL }}"{% elif defaultServer %}{{ options.name }}.Server.{{ defaultServer.name }}{% else %}""{% endif %})

    /// A list of RequestBehaviours that can be used to monitor and alter all requests
    public var behaviours: [RequestBehaviour] = []

    /// The base url prepended before every request path
    public var baseURL: String

    /// The Alamofire SessionManager used for each request
    // public var sessionManager: SessionManager
    public var httpClient: HTTPClient

    /// These headers will get added to every request
    public var defaultHeaders: [String: String]

    public var jsonDecoder = JSONDecoder()
    public var jsonEncoder = JSONEncoder()

    public var decodingQueue = DispatchQueue(label: "apiClient", qos: .utility, attributes: .concurrent)

    public init(baseURL: String, httpClient: HTTPClient = .init(eventLoopGroupProvider: .createNew), defaultHeaders: [String: String] = [:], behaviours: [RequestBehaviour] = []) {
        self.baseURL = baseURL
        // self.sessionManager = sessionManager
        self.httpClient = httpClient
        self.behaviours = behaviours
        self.defaultHeaders = defaultHeaders
        jsonDecoder.dateDecodingStrategy = .custom(dateDecoder)
        jsonEncoder.dateEncodingStrategy = .formatted(RecopiAPI.dateEncodingFormatter)
    }

    /// Makes a network request
    ///
    /// - Parameters:
    ///   - request: The API request to make
    ///   - behaviours: A list of behaviours that will be run for this request. Merged with APIClient.behaviours
    ///   - completionQueue: The queue that complete will be called on
    ///   - complete: A closure that gets passed the APIResponse
    /// - Returns: A cancellable request. Not that cancellation will only work after any validation RequestBehaviours have run
    @discardableResult
    public func makeRequest<T>(_ request: APIRequest<T>, behaviours: [RequestBehaviour] = []) -> EventLoopFuture<APIResponse<T>> {
        // create composite behaviour to make it easy to call functions on array of behaviours
        let requestBehaviour = RequestBehaviourGroup(request: request, behaviours: self.behaviours + behaviours)

        // create the url request from the request
        var urlRequest: URLRequest
        do {
            urlRequest = try request.createURLRequest(baseURL: baseURL, encoder: jsonEncoder)
        } catch {
            let error = APIClientError.requestEncodingError(error)
            requestBehaviour.onFailure(error: error)
            let response = APIResponse<T>(request: request, result: .failure(error))
            return httpClient.eventLoopGroup.next().makeSucceededFuture(response)
        }

        // add the default headers
        if urlRequest.allHTTPHeaderFields == nil {
            urlRequest.allHTTPHeaderFields = [:]
        }
        for (key, value) in defaultHeaders {
            urlRequest.allHTTPHeaderFields?[key] = value
        }

        urlRequest = requestBehaviour.modifyRequest(urlRequest)

        // let cancellableRequest = CancellableRequest(request: request.asAny())

        let resultPromise = httpClient.eventLoopGroup.next().makePromise(of: APIResponse<T>.self)
        
        requestBehaviour.validate(urlRequest) { result in
            switch result {
            case .success(let urlRequest):
                let f = self.makeNetworkRequest(request: request, urlRequest: urlRequest, requestBehaviour: requestBehaviour)
                resultPromise.completeWith(f)
            case .failure(let error):
                let error = APIClientError.validationError(error)
                let response = APIResponse<T>(request: request, result: .failure(error), urlRequest: urlRequest)
                requestBehaviour.onFailure(error: error)
                // complete(response)
                resultPromise.succeed(response)
            }
        }
        return resultPromise.futureResult
    }

    private func makeNetworkRequest<T>(request: APIRequest<T>, urlRequest: URLRequest, requestBehaviour: RequestBehaviourGroup) -> EventLoopFuture<APIResponse<T>> {
        requestBehaviour.beforeSend()

        if request.service.isUpload {
            fatalError("TODO")
            /*sessionManager.upload(
                multipartFormData: { multipartFormData in
                    for (name, value) in request.formParameters {
                        if let file = value as? UploadFile {
                            switch file.type {
                            case let .url(url):
                                if let fileName = file.fileName, let mimeType = file.mimeType {
                                    multipartFormData.append(url, withName: name, fileName: fileName, mimeType: mimeType)
                                } else {
                                    multipartFormData.append(url, withName: name)
                                }
                            case let .data(data):
                                if let fileName = file.fileName, let mimeType = file.mimeType {
                                    multipartFormData.append(data, withName: name, fileName: fileName, mimeType: mimeType)
                                } else {
                                    multipartFormData.append(data, withName: name)
                                }
                            }
                        } else if let url = value as? URL {
                            multipartFormData.append(url, withName: name)
                        } else if let data = value as? Data {
                            multipartFormData.append(data, withName: name)
                        } else if let string = value as? String {
                            multipartFormData.append(Data(string.utf8), withName: name)
                        }
                    }
                },
                with: urlRequest,
                encodingCompletion: { result in
                    switch result {
                    case .success(let uploadRequest, _, _):
                        cancellableRequest.networkRequest = uploadRequest
                        uploadRequest.responseData { dataResponse in
                            self.handleResponse(request: request, requestBehaviour: requestBehaviour, dataResponse: dataResponse, completionQueue: completionQueue, complete: complete)
                        }
                    case .failure(let error):
                        let apiError = APIClientError.requestEncodingError(error)
                        requestBehaviour.onFailure(error: apiError)
                        let response = APIResponse<T>(request: request, result: .failure(apiError))

                        completionQueue.async {
                            complete(response)
                        }
                    }
            })*/
        } else {
            let headers = urlRequest.allHTTPHeaderFields!.reduce(into: HTTPHeaders()) {
                $0.add(name: $1.key, value: $1.value)
            }
            do {
                let req = try HTTPClient.Request(url: urlRequest.url!,
                                             method: HTTPMethod(rawValue: urlRequest.httpMethod!),
                                             headers: headers,
                                             body: urlRequest.httpBody != nil ? .data(urlRequest.httpBody!) : nil)
                return handleResponse(request: request,
                                      urlRequest: urlRequest,
                                      requestBehaviour: requestBehaviour,
                                      response: httpClient.execute(request: req))
            } catch {
                return httpClient.eventLoopGroup.next().makeFailedFuture(error)
            }
            // cancellableRequest.networkRequest = networkRequest
        }
    }

    private func handleResponse<T>(request: APIRequest<T>, urlRequest: URLRequest, requestBehaviour: RequestBehaviourGroup, response: EventLoopFuture<HTTPClient.Response>) -> EventLoopFuture<APIResponse<T>> {

        
        
        func handleOnResponse(result: APIResult<T>, data: Data?) -> APIResponse<T> {
            let response = APIResponse<T>(request: request, result: result, urlRequest: urlRequest, urlResponse: nil, data: data)
            requestBehaviour.onResponse(response: response.asAny())
            return response
        }
        
        return response.flatMapThrowing({ res -> APIResponse<T> in
            let bodyData = res.body != nil ? Data(buffer: res.body!) : nil
            
            let result: APIResult<T>
            
            do {
                let statusCode = Int(res.status.code)
                let decoded = try T(statusCode: statusCode, data: bodyData ?? Data(), decoder: self.jsonDecoder)
                result = .success(decoded)
                if decoded.successful {
                    requestBehaviour.onSuccess(result: decoded.response as Any)
                }
            } catch let error {
                let apiError: APIClientError
                if let error = error as? DecodingError {
                    apiError = APIClientError.decodingError(error)
                } else if let error = error as? APIClientError {
                    apiError = error
                } else {
                    apiError = APIClientError.unknownError(error)
                }

                result = .failure(apiError)
                requestBehaviour.onFailure(error: apiError)
            }
            
            return handleOnResponse(result: result, data: bodyData)
        }).flatMapErrorThrowing { error in
            let apiError = APIClientError.networkError(error)
            let result = APIResult<T>.failure(apiError)
            requestBehaviour.onFailure(error: apiError)
            return handleOnResponse(result: result, data: nil)
        }
        
    }
}

/*
public class CancellableRequest {
    /// The request used to make the actual network request
    public let request: AnyRequest

    init(request: AnyRequest) {
        self.request = request
    }
    var networkRequest: Request?

    /// cancels the request
    public func cancel() {
        if let networkRequest = networkRequest {
            networkRequest.cancel()
        }
    }
}*/

// Helper extension for sending requests
extension APIRequest {

    /// makes a request using the default APIClient. Change your baseURL in APIClient.default.baseURL
    public func makeRequest() -> EventLoopFuture<APIResponse<ResponseType>> {
        return APIClient.default.makeRequest(self)
    }
}

// Create URLRequest
extension APIRequest {

    /// pass in an optional baseURL, otherwise URLRequest.url will be relative
    public func createURLRequest(baseURL: String = "", encoder: RequestEncoder = JSONEncoder()) throws -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = service.method
        urlRequest.allHTTPHeaderFields = headers

        // filter out parameters with empty string value
        var queryParams: [String: Any] = [:]
        for (key, value) in queryParameters {
            if String.init(describing: value) != "" {
                queryParams[key] = value
            }
        }
        if !queryParams.isEmpty {
            var urlComps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            urlComps.queryItems = queryParams.reduce(into: [], { $0.append(URLQueryItem(name: $1.key, value: "\($1.value)")) })
            urlRequest.url = urlComps.url
        }

        var formParams: [String: Any] = [:]
        for (key, value) in formParameters {
            if String.init(describing: value) != "" {
                formParams[key] = value
            }
        }
        if !formParams.isEmpty {
            // TODO:
            // urlRequest = try URLEncoding.httpBody.encode(urlRequest, with: formParams)
        }
        if let encodeBody = encodeBody {
            urlRequest.httpBody = try encodeBody(encoder)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }
}
