//
//  FileStatusWatcher.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import Foundation

final class FileStatusWatcher {
    private weak var viewModel: PetViewModel?
    private var source: DispatchSourceFileSystemObject?
    private let filePath = "/tmp/pet_status.json"
    
    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
    }
    
    func start() {
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: "{}".data(using: .utf8), attributes: nil)
        }
        
        let fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: open(filePath, O_EVTONLY),
            eventMask: .write,
            queue: .main
        )
        source?.setEventHandler { [weak self] in
            self?.readStatusFile()
        }
        source?.resume()
    }
    
    private func readStatusFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
        let statusReq = try? JSONDecoder().decode(StatusRequest.self, from: data) else { return }
        
        DispatchQueue.main.async {
            self.viewModel?.updateStatus(statusString: statusReq.status, message: statusReq.message)
        }
        
    }
}
