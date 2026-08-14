import Foundation
import simd

// What a user study produces, and where it is kept.
//
// In:  the setup screen, then the measuring and packing screens as each box is completed.
// Out: a StudyRun per participant, written to Documents/StudyRuns/<id>/ as run.json, one JPEG per
//      object, and a plain-text report.
//
// Writes are append-only and there is deliberately no delete path anywhere in this file or the UI.
// A run is written as soon as it is created and rewritten after every change, so a crash mid-study
// loses at most the box in progress.

/// The two payload modules a participant fills. Both are asked for; the order is randomised per
/// participant by the person running the study.
enum StudyBox: String, Codable, CaseIterable, Identifiable, Sendable {
    case big
    case small

    var id: String { rawValue }

    var sizeMillimetres: SIMD3<Double> {
        switch self {
        case .big: SIMD3(600, 200, 100)
        case .small: SIMD3(200, 200, 100)
        }
    }

    var title: String {
        switch self {
        case .big: "Big — 600 × 200 × 100 mm"
        case .small: "Small — 200 × 200 × 100 mm"
        }
    }

    var shortTitle: String {
        switch self {
        case .big: "Big box"
        case .small: "Small box"
        }
    }

    var other: StudyBox { self == .big ? .small : .big }
}

/// The three timed phases of one box.
enum StudyPhase: String, Codable, CaseIterable, Sendable {
    case measure
    case pack
    case payload

    var title: String {
        switch self {
        case .measure: "Measuring"
        case .pack: "Boxing and weighing"
        case .payload: "Loading the payload"
        }
    }
}

struct StudyObjectRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var measuredSizeMillimetres: [Double]
    var packagedSizeMillimetres: [Double]
    var assignedBoxName: String?
    var isOwnBox: Bool
    var hasEnforcedSize: Bool
    var massKilograms: Double?
    /// File name inside the run's photos folder, if a snapshot was captured.
    var photoFileName: String?
    /// Nil when the object was left out of the plan.
    var placementOriginMillimetres: [Double]?

    var measuredSizeText: String {
        Self.sizeText(measuredSizeMillimetres)
    }

    var packagedSizeText: String {
        Self.sizeText(packagedSizeMillimetres)
    }

    static func sizeText(_ values: [Double]) -> String {
        guard values.count == 3 else { return "—" }
        return String(format: "%.0f × %.0f × %.0f mm", values[0], values[1], values[2])
    }
}

struct StudyBoxResult: Codable, Identifiable, Sendable {
    var box: StudyBox
    var startedAt: Date
    var completedAt: Date?
    var phaseSeconds: [String: Double] = [:]
    var objects: [StudyObjectRecord] = []
    var loadedObjectIDs: [UUID] = []
    var unloadedObjectNames: [String] = []
    var packingMode: String?
    var centreOfMassMillimetres: [Double]?
    var unbalancingIndexMillimetres: Double?

    var id: String { box.rawValue }

    func seconds(for phase: StudyPhase) -> Double? {
        phaseSeconds[phase.rawValue]
    }

    var totalSeconds: Double {
        StudyPhase.allCases.compactMap { phaseSeconds[$0.rawValue] }.reduce(0, +)
    }
}

struct StudyRun: Codable, Identifiable, Sendable {
    var id: UUID
    var participantName: String
    var studyDate: Date
    var createdAt: Date
    /// Raw value of MeasurementFlow.
    var flow: String
    var firstBox: StudyBox
    var boxes: [StudyBoxResult] = []

    var isComplete: Bool {
        StudyBox.allCases.allSatisfy { box in
            boxes.first(where: { $0.box == box })?.completedAt != nil
        }
    }

    var boxOrder: [StudyBox] {
        [firstBox, firstBox.other]
    }

    func result(for box: StudyBox) -> StudyBoxResult? {
        boxes.first { $0.box == box }
    }

    var totalSeconds: Double {
        boxes.reduce(0.0) { $0 + $1.totalSeconds }
    }
}

// MARK: - Formatting

extension StudyRun {
    static func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(seconds.rounded())
        return whole >= 60
            ? String(format: "%d min %02d s", whole / 60, whole % 60)
            : "\(whole) s"
    }

    static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var reportFileName: String {
        let safeName = participantName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stamp = Self.fileDateFormatter.string(from: studyDate)
        return "payloadmeasure-\(safeName.isEmpty ? "participant" : safeName)-\(stamp).txt"
    }

    /// The whole run as plain text. Written automatically when the run completes and re-writable on
    /// demand from the results screen.
    func reportText() -> String {
        var lines: [String] = []
        lines.append("PayloadMeasure user study")
        lines.append("=========================")
        lines.append("Participant : \(participantName)")
        lines.append("Study date  : \(Self.displayDateFormatter.string(from: studyDate))")
        lines.append("Recorded    : \(Self.displayDateFormatter.string(from: createdAt))")
        lines.append("Method      : \(flow)")
        lines.append("Box order   : \(boxOrder.map(\.shortTitle).joined(separator: " then "))")
        lines.append("Run id      : \(id.uuidString)")
        lines.append("")

        for box in boxOrder {
            guard let result = result(for: box) else {
                lines.append("\(box.shortTitle): not started")
                lines.append("")
                continue
            }
            lines.append("-------------------------------------------------------------")
            lines.append("\(box.shortTitle)  (\(box.title))")
            lines.append("-------------------------------------------------------------")
            lines.append("Started   : \(Self.displayDateFormatter.string(from: result.startedAt))")
            if let completedAt = result.completedAt {
                lines.append("Completed : \(Self.displayDateFormatter.string(from: completedAt))")
            } else {
                lines.append("Completed : not finished")
            }
            lines.append("")
            lines.append("Timings")
            for phase in StudyPhase.allCases {
                lines.append(
                    "  \(phase.title.padding(toLength: 22, withPad: " ", startingAt: 0))"
                        + Self.durationText(result.seconds(for: phase))
                )
            }
            lines.append(
                "  \("Total".padding(toLength: 22, withPad: " ", startingAt: 0))"
                    + Self.durationText(result.totalSeconds)
            )
            lines.append("")

            if let mode = result.packingMode {
                lines.append("Packing version : \(mode)")
            }
            if let centre = result.centreOfMassMillimetres, centre.count == 3 {
                lines.append(
                    String(
                        format: "Balance point   : %.1f, %.1f, %.1f mm",
                        centre[0], centre[1], centre[2]
                    )
                )
            }
            if let index = result.unbalancingIndexMillimetres {
                lines.append(String(format: "Spread (U)      : %.1f mm", index))
            }
            lines.append("")

            lines.append("Objects (\(result.objects.count))")
            for (offset, object) in result.objects.enumerated() {
                let loaded = result.loadedObjectIDs.contains(object.id) ? "loaded" : "NOT loaded"
                lines.append("  \(offset + 1). \(object.name)  [\(loaded)]")
                lines.append("     measured  : \(object.measuredSizeText)")
                lines.append("     packed as : \(object.packagedSizeText)")
                if object.isOwnBox {
                    lines.append("     package   : the object itself (already a box)")
                } else if object.hasEnforcedSize {
                    lines.append("     package   : size entered by hand")
                } else {
                    lines.append("     package   : \(object.assignedBoxName ?? "none assigned")")
                }
                if let mass = object.massKilograms {
                    lines.append(String(format: "     weight    : %.0f g", mass * 1000))
                }
                if let origin = object.placementOriginMillimetres, origin.count == 3 {
                    lines.append(
                        String(
                            format: "     placed at : %.0f, %.0f, %.0f mm (bottom-left-back)",
                            origin[0], origin[1], origin[2]
                        )
                    )
                }
                if let photo = object.photoFileName {
                    lines.append("     photo     : photos/\(photo)")
                }
            }
            lines.append("")
        }

        lines.append("-------------------------------------------------------------")
        lines.append("End of report")
        return lines.joined(separator: "\n")
    }
}
