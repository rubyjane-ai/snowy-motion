import Foundation

public final class SnowDrift {
    public internal(set) var surface: Surface
    public internal(set) var heights: [Float]
    let spacing: Float
    private var scratch: [Float]
    private var capacities: [Float]
    private var deposition: [Float]
    private var baseCapacities: [Float]
    private var baseDeposition: [Float]
    private var snowfallCapacities: [Float]
    private(set) var cornerWind: [CornerWindEffect]

    init(surface: Surface, cellCount: Int, windEffects: [CornerWindEffect]? = nil) {
        self.surface = surface
        let count = max(2, cellCount)
        spacing = surface.width / Float(count - 1)
        heights = Array(repeating: 0, count: count)
        scratch = heights
        capacities = heights
        deposition = heights
        baseCapacities = heights
        baseDeposition = heights
        snowfallCapacities = heights
        cornerWind = windEffects?.count == count ? windEffects! : Array(repeating: .neutral, count: count)
        let phase = Float(surface.id % 997) * 0.17
        // The shallow Dock ridge should reach its rounded shoulders before tapering.
        let taperWidth: Float = surface.isDock ? min(6, surface.width / 2)
            : (surface.width < 16 ? surface.width / 2 : 13)
        let limit: Float
        if surface.id == DesktopSceneBuilder.groundID { limit = 28 }
        else if surface.isDock { limit = 13 }
        else if surface.releasesSnowWhenRemoved && !surface.isElevated {
            limit = min(18, max(4, surface.width * 0.32))
        } else { limit = 18 }
        for i in 0..<count {
            let x = Float(i) * spacing
            let edge = surface.id == DesktopSceneBuilder.groundID ? 1 : min(1, min(x, surface.width - x) / taperWidth)
            let taper = edge * edge * (3 - 2 * edge)
            // A tilted support holds snow up to a level line `limit` above its lowest point.
            let cap = max(0, limit - max(surface.slope * (surface.width - x), -surface.slope * x))
            // Fixed broad lobes: no shimmering noise or random per-frame bumps.
            let lobe = 0.68 + sin(x * 0.027 + phase) * 0.18
                + sin(x * 0.071 + phase * 2) * 0.09
                + sin(x * 0.13 + phase) * 0.05
            capacities[i] = cap * taper
            baseCapacities[i] = cap * lobe * taper
            snowfallCapacities[i] = baseCapacities[i]
            deposition[i] = (0.18 + lobe * 0.17) * taper
            // A sub-point dusting makes a discovered edge visible immediately, then builds gradually.
            heights[i] = surface.isSnowExposed(at: x) && !cornerWind[i].clear ? min(capacities[i], 0.6 * taper) : 0
        }
        baseDeposition = deposition
        applyCornerWind(cornerWind)
    }

    func applyCornerWind(_ effects: [CornerWindEffect]) {
        guard effects.count == heights.count else { return }
        cornerWind = effects
        for i in heights.indices {
            // Wind changes incoming snowfall, never the physical space available to pushed snow.
            snowfallCapacities[i] = effects[i].clear ? 0 : min(capacities[i], baseCapacities[i] * effects[i].capacityScale)
            deposition[i] = baseDeposition[i] * effects[i].depositionScale
        }
    }

    public func height(at localX: Float) -> Float {
        guard localX >= 0, localX <= surface.width, spacing > 0 else { return 0 }
        let coordinate = localX / spacing
        let left = min(heights.count - 2, Int(coordinate))
        let t = coordinate - Float(left)
        return heights[left] + (heights[left + 1] - heights[left]) * t
    }

    func accumulate(dt: Float, intensity: Float) {
        for i in heights.indices where surface.isSnowExposed(at: Float(i) * spacing) {
            if heights[i] < snowfallCapacities[i] {
                heights[i] = min(snowfallCapacities[i], heights[i] + deposition[i] * dt * intensity)
            }
        }
    }

    func deposit(at localX: Float, amount: Float) {
        let center = Int((localX / spacing).rounded())
        for offset in -2...2 {
            let i = center + offset
            guard heights.indices.contains(i), surface.isExposed(at: Float(i) * spacing) else { continue }
            let weight: Float = offset == 0 ? 0.44 : (abs(offset) == 1 ? 0.23 : 0.05)
            heights[i] = min(capacities[i], heights[i] + amount * weight)
        }
    }

    /// Area in square points, independent of profile resolution. Returns mass that could not fit.
    func depositMass(at localX: Float, mass: Float, direction: Float = 0, snowfall: Bool = false) -> Float {
        guard mass.isFinite, mass > 0 else { return 0 }
        guard localX >= 0, localX <= surface.width else { return mass }
        let coordinate = localX / spacing
        let center = max(0, min(heights.count - 1, Int(direction > 0 ? ceil(coordinate)
            : (direction < 0 ? floor(coordinate) : coordinate.rounded()))))
        if snowfall && (!surface.isSnowExposed(at: localX) || cornerWind[center].clear) { return mass }
        var remaining = mass
        for distance in 0...24 {
            for side in 0..<((distance == 0 || direction != 0) ? 1 : 2) {
                let i = center + (direction < 0 ? -distance : (side == 0 ? distance : -distance))
                guard heights.indices.contains(i), surface.isExposed(at: Float(i) * spacing) else { continue }
                if snowfall && (!surface.isSnowExposed(at: Float(i) * spacing) || cornerWind[i].clear) { continue }
                let capacity = snowfall ? snowfallCapacities[i] : capacities[i]
                let accepted = min(remaining, max(0, capacity - heights[i]) * spacing)
                heights[i] += accepted / spacing
                remaining -= accepted
                if remaining <= 0.0001 { return 0 }
            }
        }
        return remaining
    }

    /// Relaxes the pile toward level. `dt` scales the transfer so it can run every frame
    /// (smooth motion) with the same overall speed as the former fixed 0.1 s step.
    /// Returns the largest single transfer, so callers know whether the pile is visibly moving.
    @discardableResult
    func settle(dt: Float = 0.1, tilt: Float = 0) -> Float {
        let rate = dt.isFinite ? max(0, min(0.24, 1.2 * dt)) : 0.12
        var moved: Float = 0
        // Pairwise transfers preserve volume, including when adjacent samples are full.
        for i in heights.indices { scratch[i] = heights[i] }
        for i in 0..<(heights.count - 1) {
            guard surface.isExposed(at: Float(i) * spacing),
                  surface.isExposed(at: Float(i + 1) * spacing) else { continue }
            // A tilted support's base drop drives snow toward its lower end until the cap is level.
            // ponytail: no angle of repose and no spill off the low end; full low-end samples just stop.
            // `tilt` is the laptop's sideways tilt: it leans every pile toward the lower side.
            let flux = (heights[i] - heights[i + 1] + (surface.slope + tilt) * spacing) * rate
            let from = flux > 0 ? i : i + 1
            let to = flux > 0 ? i + 1 : i
            let transfer = min(abs(flux), min(scratch[from], max(0, capacities[to] - scratch[to])))
            scratch[from] -= transfer
            scratch[to] += transfer
            moved = max(moved, transfer)
        }
        swap(&heights, &scratch)
        return moved
    }

    /// Shaking knocks a share of the cap off its nearer end (`side` −1…1 biases which end).
    /// Reports at most one spill per end: (local x, height, area). Returns true when snow moved.
    @discardableResult
    func shed(fraction: Float, side: Float, spill: (Float, Float, Float) -> Void) -> Bool {
        guard fraction.isFinite, fraction > 0, spacing > 0, surface.width > 0 else { return false }
        let share = min(1, fraction)
        let bias = side.isFinite ? max(-1, min(1, side)) * 0.3 : 0
        var leftArea: Float = 0, rightArea: Float = 0
        var leftHeight: Float = 0, rightHeight: Float = 0
        for i in heights.indices where heights[i] > 0.0001 {
            let amount = heights[i] * share
            heights[i] -= amount
            if Float(i) * spacing / surface.width + bias >= 0.5 {
                rightArea += amount * spacing
                rightHeight = max(rightHeight, amount)
            } else {
                leftArea += amount * spacing
                leftHeight = max(leftHeight, amount)
            }
        }
        if leftArea > 0.0001 { spill(-spacing, max(leftHeight, 0.5), leftArea) }
        if rightArea > 0.0001 { spill(surface.width + spacing, max(rightHeight, 0.5), rightArea) }
        return leftArea + rightArea > 0.0001
    }

    /// Inertia while the support is dragged quickly: the cap slides `shift` points along the
    /// support (opposite to the drag). Material pushed past either end, or beyond a sample's
    /// capacity, is handed to `spill` (local x, column height, area) so it can fall freely.
    func slide(by shift: Float, spill: (Float, Float, Float) -> Void) {
        guard shift.isFinite, abs(shift) > 0.01, spacing > 0, heights.count >= 2 else { return }
        for i in heights.indices { scratch[i] = 0 }
        for i in heights.indices where heights[i] > 0.0001 {
            let target = Float(i) * spacing + shift
            guard target >= 0, target <= surface.width else {
                spill(target, heights[i], heights[i] * spacing)
                continue
            }
            let coordinate = target / spacing
            let left = max(0, min(heights.count - 2, Int(coordinate)))
            let t = max(0, min(1, coordinate - Float(left)))
            scratch[left] += heights[i] * (1 - t)
            scratch[left + 1] += heights[i] * t
        }
        let trailingEdge: Float = shift < 0 ? -spacing : surface.width + spacing
        for i in heights.indices {
            let excess = scratch[i] - capacities[i]
            if excess > 0.0001 {
                scratch[i] = capacities[i]
                spill(trailingEdge, excess, excess * spacing)
            }
        }
        swap(&heights, &scratch)
    }

    func copySnow(from previous: SnowDrift) {
        for i in heights.indices {
            heights[i] = min(capacities[i], previous.height(at: Float(i) * spacing))
        }
    }

    func clear() {
        for i in heights.indices { heights[i] = 0 }
    }
}
