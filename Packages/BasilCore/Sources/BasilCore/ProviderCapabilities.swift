/// What a provider can do. Operations pick strategies from these, never from the provider type.
public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let read              = Self(rawValue: 1 << 0)
    public static let write             = Self(rawValue: 1 << 1)
    public static let randomAccessRead  = Self(rawValue: 1 << 2)
    public static let randomAccessWrite = Self(rawValue: 1 << 3)
    public static let rename            = Self(rawValue: 1 << 4)
    /// rename() replaces the destination atomically.
    public static let atomicRename      = Self(rawValue: 1 << 5)
    public static let setPermissions    = Self(rawValue: 1 << 6)
    public static let setDates          = Self(rawValue: 1 << 7)
    public static let extendedAttrs     = Self(rawValue: 1 << 8)
    /// Copy-on-write clones within the same volume (APFS clonefile).
    public static let clone             = Self(rawValue: 1 << 9)
    public static let serverSideCopy    = Self(rawValue: 1 << 10)
    public static let checksums         = Self(rawValue: 1 << 11)
    public static let watch             = Self(rawValue: 1 << 12)
    public static let symlinks          = Self(rawValue: 1 << 13)
}
