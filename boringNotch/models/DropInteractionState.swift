//
//  DropInteractionState.swift
//  boringNotch
//

import Observation

@Observable
final class DropInteractionState {
    var notchTargeting = false
    var shelfTargeting = false
    var dropZoneTargeting = false
    var dropEvent = false

    var anyDropZoneTargeting: Bool {
        notchTargeting || shelfTargeting || dropZoneTargeting
    }
}
