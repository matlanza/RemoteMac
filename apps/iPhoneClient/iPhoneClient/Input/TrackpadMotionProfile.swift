import UIKit

enum TrackpadMotionProfile {
    static func adjusted(
        delta: CGPoint,
        velocity: CGPoint
    ) -> CGPoint {
        let speed = hypot(
            velocity.x,
            velocity.y
        )

        let gain: CGFloat

        switch speed {
        case ..<100:
            gain = 0.55

        case 100..<300:
            gain = interpolate(
                speed,
                from: 100,
                to: 300,
                start: 0.55,
                end: 0.85
            )

        case 300..<700:
            gain = interpolate(
                speed,
                from: 300,
                to: 700,
                start: 0.85,
                end: 1.20
            )

        case 700..<1400:
            gain = interpolate(
                speed,
                from: 700,
                to: 1400,
                start: 1.20,
                end: 1.70
            )

        default:
            let extra =
                min(
                    0.65,
                    (speed - 1400)
                    / 1800
                    * 0.65
                )

            gain = 1.70 + extra
        }

        var result = CGPoint(
            x: delta.x * gain,
            y: delta.y * gain
        )

        result.x = clamp(
            result.x,
            limit: 90
        )

        result.y = clamp(
            result.y,
            limit: 90
        )

        return result
    }

    private static func interpolate(
        _ value: CGFloat,
        from lower: CGFloat,
        to upper: CGFloat,
        start: CGFloat,
        end: CGFloat
    ) -> CGFloat {
        let progress =
            min(
                1,
                max(
                    0,
                    (value - lower)
                    / (upper - lower)
                )
            )

        return start
            + (
                end - start
            )
            * progress
    }

    private static func clamp(
        _ value: CGFloat,
        limit: CGFloat
    ) -> CGFloat {
        min(
            limit,
            max(
                -limit,
                value
            )
        )
    }
}
