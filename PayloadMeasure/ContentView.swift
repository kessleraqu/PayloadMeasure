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
    @State private var captureEngine = ObjectCaptureEngine()

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                measurementEngine: measurementEngine,
                captureEngine: captureEngine
            )
            .ignoresSafeArea()

            MeasurementOverlayView(
                sessionManager: sessionManager,
                measurementEngine: measurementEngine,
                captureEngine: captureEngine
            )
        }
    }
}

#Preview {
    ContentView()
}
