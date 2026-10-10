//
//  DisplaySink.swift
//  AgentPets
//

import AgentPetsCore

/// 集約した表示状態の出力先。画面のペットのほか、第 2 期で BLE をここに足す。
protocol DisplaySink: AnyObject {
    func show(_ display: DisplayState)
}
