//
//  PetViewModel.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import Foundation
import Observation

@MainActor
@Observable
final class PetViewModel {
    var currentState: PetState = .idle
    var message: String = ""
    
    private var guardTimer: Timer?
    
    func updateStatus(statusString: String, message: String?) {
        guard let newState = PetState(rawValue: statusString) else {
            return
        }
        
        self.currentState = newState
        self.message = message ?? ""
        
        guardTimer?.invalidate()
        if newState == .working {
            guardTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                    Task { [weak self] in
                        await MainActor.run {
                            guard let strongSelf = self else { return }
                            if strongSelf.currentState == .working {
                                strongSelf.currentState = .idle
                                strongSelf.message = ""
                                strongSelf.updateStatus(statusString: "idle", message: nil)
                            }
                        }
                    }
                }
        }
        
    }
}
