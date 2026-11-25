import Foundation

/// Physical motion of the laptop, read by the optional snowy-motion helper.
public struct DeviceMotion: Equatable, Sendable {
    /// Sideways tilt as the sine of the angle: positive = right side lower. −1…1.
    public var tilt: Float
    /// Strength of shaking, in g above steady gravity (0 when the laptop is still).
    public var shake: Float
    /// Sideways share of the latest jolt, −1…1 (which way snow is thrown).
    public var shakeSide: Float

    public init(tilt: Float = 0, shake: Float = 0, shakeSide: Float = 0) {
        self.tilt = tilt.isFinite ? max(-1, min(1, tilt)) : 0
        self.shake = shake.isFinite ? max(0, min(4, shake)) : 0
        self.shakeSide = shakeSide.isFinite ? max(-1, min(1, shakeSide)) : 0
    }

    public static let still = DeviceMotion()
}

extension SnowSimulation {
    /// Tilt below about 3° is ignored, so a slightly uneven desk does not drift the snow.
    static let tiltDeadZone: Float = 0.05
    /// Shaking below this many g (typing, a bump on the desk) is ignored.
    static let shakeThreshold: Float = 0.15

    var effectiveTilt: Float {
        let tilt = motion.tilt
        let zone = SnowSimulation.tiltDeadZone
        guard abs(tilt) > zone else { return 0 }
        return tilt > 0 ? tilt - zone : tilt + zone
    }

    var effectiveShake: Float { max(0, motion.shake - SnowSimulation.shakeThreshold) }

    /// Sideways push (points per second) that tilt and shaking give to falling and loose snow.
    func motionPush() -> Float {
        guard !reducedMotion else { return 0 }
        let jitter = sin(elapsed * 37)
        return effectiveTilt * 220 + motion.shakeSide * effectiveShake * 260 * jitter
    }

    /// Strong tilt slides window caps toward the lower edge and over it; shaking knocks
    /// snow off window edges and bounces snow lying on the floor and the Dock.
    /// Returns true when a pile changed.
    func applyDeviceMotion(dt: Float) -> Bool {
        let tilt = effectiveTilt
        let shake = effectiveShake
        guard !reducedMotion, tilt != 0 || shake > 0, budget.cells > 0, dt.isFinite, dt > 0 else { return false }
        var changed = false
        let seed = UInt32(truncatingIfNeeded: Int(elapsed * 997))
        for drift in drifts {
            let surface = drift.surface
            if surface.isDock || surface.id == DesktopSceneBuilder.groundID {
                // Snow resting on the floor and the Dock has nowhere to fall: shaking bounces it.
                if shake > 0, kickRestingSnow(drift, shake: shake, dt: dt, seed: seed) { changed = true }
                continue
            }
            guard !surface.isElevated, abs(surface.slope) < 0.0001 else { continue }
            if abs(tilt) > 0.2 {
                let shift = (tilt > 0 ? 1 : -1) * (abs(tilt) - 0.2) * 90 * dt
                drift.slide(by: shift) { localX, height, mass in
                    self.releaseFromCap(surface, localX: localX, height: height, mass: mass)
                }
                changed = true
            }
            if shake > 0 {
                let fraction = 1 - exp(-min(6, shake * 4) * dt)
                let side = motion.shakeSide
                if drift.shed(fraction: fraction, side: side, spill: { localX, height, mass in
                    self.releaseFromCap(surface, localX: localX, height: height, mass: mass)
                }) {
                    changed = true
                }
            }
        }
        return changed
    }

    /// Pops clumps of a resting pile up into the air as loose snow, which falls and lands again.
    func kickRestingSnow(_ drift: SnowDrift, shake: Float, dt: Float, seed: UInt32) -> Bool {
        guard looseSnow.maximumActive > 0 else { return false }
        let surface = drift.surface
        let chance = 1 - exp(-min(6, shake * 10) * dt)
        let throwHeight = min(80, 20 + shake * 90)
        let side = motion.shakeSide
        return drift.kick(share: 0.5, pick: { SnowSimulation.motionNoise($0, seed) < chance }) { localX, height, mass in
            let n = SnowSimulation.motionNoise(Int(localX * 8), seed &+ 0x51ED)
            let x = max(1, min(self.size.x - 1, surface.x + localX + side * (n - 0.25) * 30))
            let base = surface.baseY(at: max(0, min(surface.width, localX)))
            let y = max(1, min(self.size.y - 1, base - height - 6 - n * throwHeight))
            let left = self.looseSnow.add(mass: mass, at: SIMD2(x, y), direction: SIMD2(0, -1))
            if left > 0.0001 {
                // No room in the air right now: keep it queued so no snow is lost.
                self.retainRelease(SnowRelease(position: SIMD2(x, y), height: height, mass: left),
                                   in: &self.snowReleases)
            }
        }
    }

    /// Cheap repeatable noise in 0..<1 for picking which clumps pop.
    static func motionNoise(_ i: Int, _ seed: UInt32) -> Float {
        var h = (UInt32(truncatingIfNeeded: i) &* 0x9E37_79B1) ^ (seed &* 0x85EB_CA77)
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return Float(h & 0xFF_FFFF) / Float(0x100_0000)
    }

    func releaseFromCap(_ surface: Surface, localX: Float, height: Float, mass: Float) {
        let x = max(1, min(size.x - 1, surface.x + localX))
        let base = surface.baseY(at: max(0, min(surface.width, localX)))
        let y = max(1, min(size.y - 1, base - height * 0.5))
        retainRelease(SnowRelease(position: SIMD2(x, y), height: max(0.1, height), mass: mass), in: &snowReleases)
    }
}
