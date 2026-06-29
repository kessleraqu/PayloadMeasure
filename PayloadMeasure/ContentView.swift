//
//  ContentView.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var sessionManager = ARSessionManager()
    @State private var measurementEngine = MeasurementEngine()

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                measurementEngine: measurementEngine
            )
            .ignoresSafeArea()

            MeasurementOverlayView(
                sessionManager: sessionManager,
                measurementEngine: measurementEngine
            )
        }
    }
}

#Preview {
    ContentView()
}
