// Small fixed-size vector types in Double precision.
// Deliberately independent of simd so that the package builds on Linux.
// Convert to and from simd at the app boundary (CaptureApp, DirectorApp).

import Foundation

public struct Vec2: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }
}

public struct Vec3: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ array: [Double]) {
        precondition(array.count == 3, "Vec3 needs 3 elements")
        self.init(array[0], array[1], array[2])
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    public var array: [Double] { [x, y, z] }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public static func -= (a: inout Vec3, b: Vec3) { a = a - b }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }

    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    public var lengthSquared: Double { dot(self) }
    public var length: Double { lengthSquared.squareRoot() }

    /// Unit vector. Precondition: length > 0.
    public var normalized: Vec3 {
        let l = length
        precondition(l > 0, "cannot normalise a zero vector")
        return self / l
    }

    public func distance(to b: Vec3) -> Double { (self - b).length }

    public static func lerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        a + (b - a) * t
    }
}

public struct Vec4: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ v: Vec3, _ w: Double) {
        self.init(v.x, v.y, v.z, w)
    }

    public var xyz: Vec3 { Vec3(x, y, z) }
    public var array: [Double] { [x, y, z, w] }

    subscript(_ i: Int) -> Double {
        get {
            switch i {
            case 0: return x
            case 1: return y
            case 2: return z
            case 3: return w
            default: preconditionFailure("Vec4 index out of range")
            }
        }
        set {
            switch i {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            case 3: w = newValue
            default: preconditionFailure("Vec4 index out of range")
            }
        }
    }

    public static func + (a: Vec4, b: Vec4) -> Vec4 { Vec4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w) }
    public static func * (a: Vec4, s: Double) -> Vec4 { Vec4(a.x * s, a.y * s, a.z * s, a.w * s) }
    public func dot(_ b: Vec4) -> Double { x * b.x + y * b.y + z * b.z + w * b.w }
}
