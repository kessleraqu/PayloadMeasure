import Foundation
import simd

struct MesPoint: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    var position: SIMD3<Float>
    var isRefining = true
}
