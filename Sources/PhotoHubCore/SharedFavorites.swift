import Foundation
import AssetLibraryContract

extension FavoriteReference {
    public init(space: String = "normal", root: String, catalog: String, target: String, kind: String) {
        self.init(space: space, rootId: root, catalogId: catalog, targetId: target, kind: kind)
    }
    public var identity: String { (space == "normal" ? [space, rootId, targetId, kind] : [space, rootId, catalogId, targetId, kind]).joined(separator: "/") }
    public func updateBody(active: Bool) -> [String: Any] {
        ["reference": ["space": space, "rootId": rootId, "catalogId": catalogId, "targetId": targetId, "kind": kind], "favorite": active]
    }
}
