import Foundation

public enum LibraryOrder: String, CaseIterable, Identifiable {
    case name, reverseName, largest
    public var id: String { rawValue }
    public var title: String {
        switch self { case .name: return "名前順"; case .reverseName: return "名前の逆順"; case .largest: return "容量の大きい順" }
    }
    public func arrange<T>(_ values: [T], query: String, name: (T) -> String, size: (T) -> Int64) -> [T] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return values.filter { search.isEmpty || name($0).localizedStandardContains(search) }.sorted {
            if self == .largest, size($0) != size($1) { return size($0) > size($1) }
            let comparison = name($0).localizedStandardCompare(name($1))
            return self == .reverseName ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
}
