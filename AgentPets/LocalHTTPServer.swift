//
//  LocalHTTPServer.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import Foundation
import Network


final class LocalHTTPServer {
    private var listener: NWListener?
    
    func start(port: UInt16 = 9000) {
        guard let portOption = NWEndpoint.Port(rawValue: port) else { return }
        
        do {
            let parameters = NWParameters.tcp
            // allow only self loopback access
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: portOption)
            self.listener = try NWListener(using: parameters, on: portOption)
            
            self.listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("ready on port: \(port)")
                case .failed(let error):
                    print(error)
                default:
                    break
                }
            }
            
            self.listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }
            
            self.listener?.start(queue: .global())
        } catch {
            
        }
    }
    
    // called from the listener's @Sendable callback, touches no main-actor state
    private nonisolated func handleConnection(_ connection: NWConnection) {
        print("connected")
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { (data, _, isComplete, error) in
            guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return }
            print(requestString)
            
            if isComplete {
                print("disconnected")
                connection.cancel()
            }
            
            // parse
            if requestString.contains("POST /status") {
                if let bodyRange = requestString.range(of: "\r\n\r\n") {
                    let body = requestString[bodyRange.upperBound...]
                    if let bodyData = body.data(using: .utf8),
                       let statusRequest = try? JSONDecoder().decode(StatusRequest.self, from: bodyData) {
                        // notify UI
                        Task { @MainActor in
                            print(statusRequest)
                        }
                        
                        let response = "HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"
                        connection.send(
                            content: response.data(using: .utf8),
                            completion: .contentProcessed({_ in
                            connection.cancel()
                        }))
                        return
                    }
                }
            }
            
            let badResponse = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
            connection.send(content: badResponse.data(using: .utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }
    
}
