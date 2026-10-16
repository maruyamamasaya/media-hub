import XCTest
import AssetLibraryContract
@testable import PhotoHubCore

final class LibraryBrowseTests: XCTestCase {
    func testNaturalNameSearchAndSizeOrderDoNotMutateInput() {
        let values = [("Photo 10", Int64(5)), ("Photo 2", Int64(10)), ("Video", Int64(15))]
        let sorted = LibraryOrder.name.arrange(values, query: " PHOTO ", name: { $0.0 }, size: { $0.1 })
        XCTAssertEqual(sorted.map { $0.0 }, ["Photo 2", "Photo 10"])
        XCTAssertEqual(LibraryOrder.largest.arrange(values, query: "", name: { $0.0 }, size: { $0.1 }).map { $0.1 }, [15, 10, 5])
        XCTAssertEqual(values.first?.0, "Photo 10")
    }
    func testFavoriteIdentitySeparatesKindsAndSecretKeysButSurvivesNormalCatalogChange() {
        let first = FavoriteReference(root: "root", catalog: "old", target: "item", kind: "item")
        let next = FavoriteReference(root: "root", catalog: "new", target: "item", kind: "item")
        XCTAssertEqual(first.identity, next.identity)
        XCTAssertNotEqual(first.identity, FavoriteReference(root: "root", catalog: "old", target: "item", kind: "folder").identity)
        XCTAssertNotEqual(FavoriteReference(space: "sealed", root: "key1", catalog: "one", target: "item", kind: "item").identity,
                          FavoriteReference(space: "sealed", root: "key2", catalog: "one", target: "item", kind: "item").identity)
    }
}
