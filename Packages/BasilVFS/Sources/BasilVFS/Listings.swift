import BasilCore
import Foundation
import Synchronization

/// A provider with one folder that lists items stored in other places: search results shown in a
/// pane (Total Commander's "Feed to listbox"). The items keep their own paths, so commands on them
/// (copy, move, delete, view, edit) work on the real files. The listing holds no folders of its
/// own: nothing can be created in it.
public protocol ListingProvider: FileSystemProvider {
    /// The folder the listing belongs to (where a search started). Backspace goes back to it,
    /// names are shown relative to it, and changes to the items are allowed where they are
    /// allowed in this folder.
    var origin: VFSPath { get }
    /// What the path bar and the window title call the listing ("Search results").
    var title: String { get }
    /// Items Basil renamed or moved: the listing shows them at their new paths from now on
    /// (an item, or anything below a folder, at a `from` path).
    func itemsMoved(_ pairs: [(from: VFSPath, to: VFSPath)])
}

/// The origin and title of every registered listing, by location, for code that names a folder
/// without a registry at hand (the path bar, tab titles).
public enum Listings {
    public struct Info: Sendable, Equatable {
        public let origin: VFSPath
        public let title: String
    }

    private static let table = Mutex<[ProviderLocation: Info]>([:])

    public static func info(_ location: ProviderLocation) -> Info? { table.withLock { $0[location] } }

    static func set(_ info: Info?, for location: ProviderLocation) {
        table.withLock { $0[location] = info }
    }
}

extension ProviderRegistry {
    /// Registers a listing (also in `Listings`).
    public func register(listing: any ListingProvider) {
        Listings.set(Listings.Info(origin: listing.origin, title: listing.title), for: listing.location)
        register(listing as any FileSystemProvider)
    }

    /// The listing provider behind `location`, when it is one.
    public func listing(_ location: ProviderLocation) -> (any ListingProvider)? {
        (try? provider(for: location)) as? any ListingProvider
    }

    /// Unregisters the listings whose locations are not in `keeping` (none of the panes or tabs shows them).
    public func closeListings(keeping: Set<ProviderLocation>) {
        let unused = allProviders().filter { $0 is any ListingProvider && !keeping.contains($0.location) }
        for provider in unused {
            unregister(provider.location)
            Listings.set(nil, for: provider.location)
        }
    }
}
