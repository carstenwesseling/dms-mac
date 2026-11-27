import GRDB
import XCTest
@testable import DMS

final class XMLTextTests: XCTestCase {
    func testStripsWordXML() {
        let xml = #"<w:document><w:body><w:p><w:r><w:t>Rechnung Nr. 42</w:t></w:r></w:p><w:p><w:r><w:t>Gr&#252;&#xDF;e &amp; Dank</w:t></w:r></w:p></w:body></w:document>"#
        let text = XMLText.strip(xml)
        XCTAssertTrue(text.contains("Rechnung Nr. 42"))
        XCTAssertTrue(text.contains("Grüße & Dank"))
        XCTAssertTrue(text.contains("\n"))
    }

    func testStripsHTMLScripts() {
        let html = "<html><script>var x = 1;</script><p>Hallo</p></html>"
        XCTAssertEqual(TextExtractor.normalize(XMLText.strip(html)), "Hallo")
    }
}

final class CategoryTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(FileCategory(ext: "DOCX"), .dokumente)
        XCTAssertEqual(FileCategory(ext: "xlsx"), .tabellen)
        XCTAssertEqual(FileCategory(ext: "heic"), .bilder)
        XCTAssertEqual(FileCategory(ext: "xyz"), .sonstige)
    }
}

final class DatabaseTests: XCTestCase {
    func testSearchFindsContentAndTags() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Test", kind: .local, path: "/tmp/dms-test", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            var file = FileRecord(id: nil, sourceId: source.id!, path: "/tmp/dms-test/Rechnung_2024.pdf", name: "Rechnung_2024.pdf",
                                  ext: "pdf", typeIdentifier: nil, size: 1000, modified: Date(), created: nil, lastUsed: nil,
                                  contentHash: nil, textState: .done, scanMark: 1)
            try file.insert(db)
            try db.execute(sql: "INSERT INTO content(fileId, body, method) VALUES (?, 'Stromabrechnung Stadtwerke', 'pdf')", arguments: [file.id])
            try AppDatabase.reindexFTS(db, fileId: file.id!)
        }

        XCTAssertEqual(try db.search("Strom").count, 1, "Präfix im Inhalt")
        XCTAssertEqual(try db.search("Rechnung").count, 1, "Wort im Dateinamen")
        XCTAssertEqual(try db.search("Urlaub").count, 0)

        let fileId = try db.search("").first!.file.id!
        try db.addTag("Finanzen", to: [fileId])
        XCTAssertEqual(try db.search("Finanzen").count, 1, "Tag ist durchsuchbar")
        XCTAssertEqual(try db.tags(forFile: fileId).map(\.name), ["Finanzen"])

        let tagId = try db.allTags().first!.id!
        try db.removeTag(tagId, from: [fileId])
        XCTAssertTrue(try db.allTags().isEmpty)
    }

    func testDeletingFileRemovesItFromSearch() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Test", kind: .local, path: "/tmp/dms-test", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            var file = FileRecord(id: nil, sourceId: source.id!, path: "/tmp/dms-test/a.txt", name: "a.txt", ext: "txt",
                                  typeIdentifier: nil, size: 1, modified: Date(), created: nil, lastUsed: nil,
                                  contentHash: nil, textState: .pending, scanMark: 1)
            try file.insert(db)
            try AppDatabase.reindexFTS(db, fileId: file.id!)
            try db.execute(sql: "DELETE FROM file")
        }
        XCTAssertEqual(try db.search("a").count, 0)
    }
}

final class SearchQueryTests: XCTestCase {
    func testPlainText() {
        let q = SearchQuery(parsing: "rechnung 2024")
        XCTAssertEqual(q, SearchQuery(text: "rechnung 2024"))
    }

    func testTypeAsExtension() {
        let q = SearchQuery(parsing: "typ:PDF rechnung")
        XCTAssertEqual(q.ext, "pdf")
        XCTAssertNil(q.category)
        XCTAssertEqual(q.text, "rechnung")
    }

    func testTypeAsCategory() {
        XCTAssertEqual(SearchQuery(parsing: "typ:bilder").category, .bilder)
        XCTAssertEqual(SearchQuery(parsing: "typ:bild").category, .bilder)
        XCTAssertEqual(SearchQuery(parsing: "typ:präsentation").category, .praesentationen)
        XCTAssertEqual(SearchQuery(parsing: "typ:doc").ext, "doc")
    }

    func testSourceWithQuotes() {
        let q = SearchQuery(parsing: "quelle:\"Google Drive\" vertrag")
        XCTAssertEqual(q.sourceName, "Google Drive")
        XCTAssertEqual(q.text, "vertrag")
    }

    func testUnknownKeyStaysText() {
        XCTAssertEqual(SearchQuery(parsing: "uhrzeit:12 typ:").text, "uhrzeit:12 typ:")
    }

    func testExtensionFilterInDatabase() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Test", kind: .local, path: "/tmp/t", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            for name in ["a.pdf", "b.docx", "c.pdf"] {
                var f = FileRecord(id: nil, sourceId: source.id!, path: "/tmp/t/\(name)", name: name,
                                   ext: (name as NSString).pathExtension, typeIdentifier: nil, size: 1, modified: Date(),
                                   created: nil, lastUsed: nil, contentHash: nil, textState: .done, scanMark: 1)
                try f.insert(db)
            }
        }
        XCTAssertEqual(try db.search("", ext: "pdf").count, 2)
        XCTAssertEqual(try db.search("", category: .dokumente, ext: "docx").count, 1)
        XCTAssertEqual(try db.extensionCounts().first?.ext, "pdf")
    }
}

final class FileTreeTests: XCTestCase {
    private func row(_ id: Int64, _ path: String, size: Int64 = 10) -> FileRow {
        let url = URL(fileURLWithPath: path)
        let file = FileRecord(id: id, sourceId: 1, path: path, name: url.lastPathComponent, ext: url.pathExtension,
                              typeIdentifier: nil, size: size, modified: Date(), created: nil, lastUsed: nil,
                              contentHash: nil, textState: .done, scanMark: 1)
        return FileRow(file: file, sourceName: "Sicherung", snippet: nil)
    }

    func testFolderTree() {
        let source = Source(id: 1, name: "Sicherung", kind: .local, path: "/x", remoteURL: nil, lastScan: nil)
        let rows = [row(1, "/x/a.pdf"), row(2, "/x/Fotos/2024/Urlaub/b.jpg"), row(3, "/x/Fotos/2024/Urlaub/c.jpg"), row(4, "/x/Musik/d.mp3")]
        let tree = FileTree.folders(rows, sources: [source])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "Sicherung")
        XCTAssertEqual(tree[0].fileCount, 4)
        let names = tree[0].children?.map(\.name)
        XCTAssertEqual(names, ["Fotos/2024/Urlaub", "Musik", "a.pdf"], "Ordnerkette zusammengefasst, Ordner vor Dateien")
        XCTAssertEqual(FileTree.ancestors(of: "/x/Fotos/2024/Urlaub/b.jpg", in: tree).count, 2)
    }

    func testAlbumGroups() {
        let rows = [row(1, "/m/21_Der ultimative Ratgeber für alles.mp3"), row(2, "/m/15_Der ultimative Ratgeber für alles.mp3"),
                    row(3, "/m/22_Der ultimative Ratgeber für alles.mp3"), row(4, "/m/Anderes Lied.mp3")]
        let groups = FileTree.groups(rows)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].fileCount, 3)
        XCTAssertTrue(groups[0].name.hasPrefix("Der ultimative Ratgeber für alles"))
        XCTAssertEqual(groups[0].children?.first?.name, "15_Der ultimative Ratgeber für alles.mp3")
        XCTAssertFalse(groups[1].isFolder)
    }

    func testBaseName() {
        XCTAssertEqual(FileTree.baseName("IMG_0001.jpg"), "img")
        XCTAssertEqual(FileTree.baseName("01 - Intro.mp3"), "intro")
        XCTAssertEqual(FileTree.baseName("Vertrag (1).pdf"), "vertrag")
        XCTAssertEqual(FileTree.baseName("Hörbuch Teil 2.mp3"), "hörbuch")
    }
}
