// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

final class MediaServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = MediaWorkerService()
        connection.exportedInterface = .makeMediaWorkerInterface()
        connection.exportedObject = service
        connection.invalidationHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

let delegate = MediaServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
