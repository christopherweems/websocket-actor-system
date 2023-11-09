//
//  File 2.swift
//  
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO

class RemoteNodeConnection: Identifiable, Hashable, Equatable {
    /// The ID of the remote node.
    let id: NodeIdentity
    
    /// The address to connect or reconnect to the remote node.
    /// `nil` if the remote node does not have an fixed address (as with a mobile client).
    let address: NodeAddress?
    
    /// The current communications channel to the remote node, or nil
    /// if the connection has been lost.
    var channel: Channel?
    
    init(id: NodeIdentity, address: NodeAddress? = nil, channel: Channel? = nil) {
        self.id = id
        self.address = address
        self.channel = channel
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func ==(lhs: RemoteNodeConnection, rhs: RemoteNodeConnection) -> Bool {
        lhs.id == rhs.id
    }
}