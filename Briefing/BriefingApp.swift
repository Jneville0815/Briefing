//
//  BriefingApp.swift
//  Briefing
//
//  Created by Jimmy Neville on 4/23/26.
//

import SwiftUI

@main
struct BriefingApp: App {
    @State private var store = BriefingStore()

    var body: some Scene {
        Window("Briefing", id: "briefing") {
            BriefingView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
