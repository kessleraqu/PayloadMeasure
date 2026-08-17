import Foundation

/// One palette shared by AR masks, anchors, measured boxes, manual objects, and both packing views.
/// A study payload is limited to 15 objects, so no colour has to repeat within a payload.
nonisolated enum ObjectColourPalette {
    static let colours: [ObjectMaskDisplayColor] = [
        ObjectMaskDisplayColor(red: 1.00, green: 0.78, blue: 0.12),
        ObjectMaskDisplayColor(red: 1.00, green: 0.22, blue: 0.62),
        ObjectMaskDisplayColor(red: 0.20, green: 0.95, blue: 0.42),
        ObjectMaskDisplayColor(red: 1.00, green: 0.42, blue: 0.10),
        ObjectMaskDisplayColor(red: 0.64, green: 0.38, blue: 1.00),
        ObjectMaskDisplayColor(red: 0.20, green: 0.55, blue: 1.00),
        ObjectMaskDisplayColor(red: 1.00, green: 0.30, blue: 0.28),
        ObjectMaskDisplayColor(red: 0.16, green: 0.92, blue: 0.78),
        ObjectMaskDisplayColor(red: 0.72, green: 1.00, blue: 0.16),
        ObjectMaskDisplayColor(red: 0.78, green: 0.55, blue: 1.00),
        ObjectMaskDisplayColor(red: 0.10, green: 0.82, blue: 1.00),
        ObjectMaskDisplayColor(red: 1.00, green: 0.55, blue: 0.45),
        ObjectMaskDisplayColor(red: 0.95, green: 0.62, blue: 0.05),
        ObjectMaskDisplayColor(red: 0.45, green: 1.00, blue: 0.72),
        ObjectMaskDisplayColor(red: 0.95, green: 0.20, blue: 0.35),
    ]

    static func colour(at index: Int) -> ObjectMaskDisplayColor {
        colours[index % colours.count]
    }
}
