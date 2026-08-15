import Foundation

/// Deterministic RNG so simulations and tests reproduce exactly.
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Bundled dataset, embedded into the binary by SwiftPM.
enum AtlasResource {
    static var atlas_json: [UInt8] { PackageResources.atlas_json }
}
