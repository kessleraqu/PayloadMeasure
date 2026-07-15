# PROJECT_CONTEXT.md

# PayloadMeasure – Master's Thesis Context

## Overview

This repository contains the implementation of the research prototype developed as part of my Master's thesis.

**Thesis title**

> Using Computer Vision for Guiding Payload Distribution in Modular Drone Delivery Systems

The application is an iOS AR application intended to assist an operator during the **payload assessment and preparation** stage before a modular delivery drone is assembled and configured.

The project is a research prototype, not a commercial application.

---

# Research Background

The modular drone platform already supports AR-assisted drone reconfiguration. My contribution is the preceding workflow:

1. Assess the payload.
2. Measure the payload.
3. Estimate relevant properties.
4. Check compatibility with the modular drone platform.
5. Guide the operator during payload preparation.

The app should therefore act as an intelligent measurement and decision-support tool.

---

# Hardware

## Development machine
- MacBook Air M2

## Target and test devices

- Original target: iPhone 13 Pro with LiDAR Scanner.
- Currently available development device: iPhone 15 Plus without LiDAR.
- The app must detect LiDAR capabilities at runtime and keep unsupported workflows explicit.
- RGB camera, world tracking, plane detection, and non-depth UI work can be tested on the iPhone 15 Plus.
- Scene depth, reconstructed mesh, and metric automatic object capture still require a LiDAR-capable device.

The simulator should **never** be considered a substitute for testing AR functionality.

---

# Technologies

- Swift
- SwiftUI
- ARKit
- RealityKit
- Vision
- CoreML (optional later)

Avoid Unity unless explicitly requested.

---

# Current Development Status

Current milestone:

✅ Xcode project created

✅ Code signing configured

✅ App runs on physical iPhone

✅ Initial ARView embedded inside SwiftUI

✅ Camera permission (`NSCameraUsageDescription`) configured via build settings (`INFOPLIST_KEY_NSCameraUsageDescription`).

✅ Manual Line and Box measurement workflows implemented.

✅ LiDAR depth-based automatic Scan workflow implemented with live multi-frame accumulation.

✅ Scan is the default workflow and reports unsupported hardware explicitly on non-LiDAR devices.

✅ Live RGB foreground-instance mask preview runs in Scan mode on both LiDAR and non-LiDAR devices.

✅ RGB masks use persistent AR world anchors, appearance/geometry reacquisition, tap-again removal,
and per-object colors on both LiDAR and non-LiDAR devices.

✅ Locked masks are propagated between segmentation keyframes with dense RGB optical flow; global
one-to-one instance assignment prevents order-dependent multi-object overlap.

✅ On LiDAR hardware, automatic box geometry is fitted only from depth pixels admitted by the
time-synchronized object mask. Unmasked depth is restricted to support-plane height estimation.

✅ Environment readiness is reported at runtime: LiDAR devices wait for depth/mesh data, while
non-LiDAR devices guide the operator until camera-based plane mapping is stable.

---

# Long-Term Roadmap

## Phase 1 — Foundation

- Launch AR camera
- Start AR session
- Plane detection
- Scene depth
- Verify LiDAR

## Phase 2 — Manual Measurement

- Tap 3D points
- Compute distances
- Measure box dimensions
- Display dimensions

## Phase 3 — Assisted Measurement

- Automatic box detection
- Corner refinement
- Measurement confidence
- Export results

## Phase 4 — Payload Intelligence

Estimate:

- Length
- Width
- Height
- Volume
- Weight (estimated or entered)
- Center of mass (future)

Evaluate:

- Platform compatibility
- Arrangement possibilities
- Payload constraints

## Deferred Tracking Upgrade

After the presentation-safe native Vision version is validated, evaluate replacing foreground-mask
selection with pretrained promptable video segmentation. The leading option is EdgeTAM exported to
Core ML: tap prompts select arbitrary objects, one image encoding is shared across locks, and AR
anchor reprojection plus temporal mask state supports reacquisition. Keep synchronized mask-gated
LiDAR points for metric capture. EfficientTAM is a secondary candidate if its iOS deployment path
matures; fixed-class YOLO segmentation is appropriate only with a payload-specific training set.

---

# Software Design Principles

- Build incrementally.
- Keep every commit runnable.
- Prefer readability over abstraction.
- Explain every architectural decision.
- Minimize dependencies.
- Test on the physical iPhone after every milestone.

---

# Expected Project Structure

PayloadMeasure/
- PayloadMeasureApp.swift
- ContentView.swift
- ARCameraView.swift
- ARSessionManager.swift
- MeasurementEngine.swift
- MeasurementMode.swift
- MeasurementOverlayView.swift
- MeasurementPoint.swift
- ObjectCapture.swift
- ObjectCaptureEngine.swift
- ObjectMaskProcessor.swift
- PayloadMeasurement.swift
- CompatibilityChecker.swift
- ExportManager.swift

---

# Coding Guidelines for AI

When modifying the project:

- Read this document first.
- Make the smallest reasonable change.
- Keep the project compiling.
- Explain why each change is necessary.
- Do not perform unnecessary refactoring.
- Prefer native Apple APIs.
- Ask before introducing new frameworks.

When implementing features:

1. First explain the approach.
2. Then implement.
3. Keep code modular.
4. Add comments only where they improve understanding.

---

# Role of the AI Assistant

Act as a senior iOS + ARKit engineer.

Priorities:

1. Correctness
2. Simplicity
3. Maintainability
4. Research quality
5. Measurement accuracy

The objective is not simply to build an app, but to produce a research-quality prototype suitable for inclusion in a Master's thesis.

Always keep the research objective in mind when proposing implementations.
