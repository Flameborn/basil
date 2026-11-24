import BasilCore
import Foundation

/// Supplies a column's text for the items of a folder, when that text is not part of
/// `FileItem` (Git status). Panes ask every registered annotator after a folder loads or
/// changes, off the main thread, and show its column (`ColumnDefinition.onlyWhenAnnotated`)
/// only where it answered. Plugins register theirs the same way.
public protocol ColumnAnnotator: Sendable {
    /// The column this annotator fills.
    var column: ColumnID { get }
    /// The texts for `directory`'s items; nil when the annotator does not apply there (a folder
    /// outside any repository, or not on a local disk).
    func annotations(for directory: VFSPath, registry: ProviderRegistry) async -> ColumnAnnotation?
}

extension ProviderRegistry {
    public func register(annotator: any ColumnAnnotator) {
        annotators.withLock { $0.append(annotator) }
    }

    public var columnAnnotators: [any ColumnAnnotator] { annotators.withLock { $0 } }

    /// Removes the annotators of a column (a plugin turned off).
    public func unregisterAnnotators(of column: ColumnID) {
        annotators.withLock { $0.removeAll { $0.column == column } }
    }

    /// Every annotator's answer for `directory`, by column.
    public func annotations(for directory: VFSPath) async -> [ColumnID: ColumnAnnotation] {
        var result: [ColumnID: ColumnAnnotation] = [:]
        for annotator in columnAnnotators {
            if let answer = await annotator.annotations(for: directory, registry: self) { result[annotator.column] = answer }
        }
        return result
    }
}
