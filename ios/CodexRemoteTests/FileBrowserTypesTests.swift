import Testing
import Foundation
@testable import CodexRemote

struct FileBrowserTypesTests {
    private func decode<T: Decodable>(_ t: T.Type, _ j: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(j.utf8))
    }

    @Test func decodeReadDirectoryResponse() throws {
        let r = try decode(FsReadDirectoryResponse.self,
            #"{"entries":[{"fileName":"src","isDirectory":true,"isFile":false},{"fileName":"a.txt","isDirectory":false,"isFile":true}]}"#)
        #expect(r.entries.count == 2)
        #expect(r.entries[0].fileName == "src")
        #expect(r.entries[0].isDirectory == true)
        #expect(r.entries[1].isFile == true)
    }

    @Test func decodeReadFileResponse() throws {
        let r = try decode(FsReadFileResponse.self, #"{"dataBase64":"aGk="}"#)
        #expect(r.dataBase64 == "aGk=")
    }

    @Test func decodeGetMetadataResponse() throws {
        let r = try decode(FsGetMetadataResponse.self,
            #"{"isDirectory":false,"isFile":true,"isSymlink":false,"createdAtMs":1000,"modifiedAtMs":2000}"#)
        #expect(r.isFile == true)
        #expect(r.isSymlink == false)
        #expect(r.modifiedAtMs == 2000)
    }

    @Test func encodeParams() throws {
        let d = try JSONEncoder().encode(FsReadDirectoryParams(path: "/repo"))
        let s = String(decoding: d, as: UTF8.self)
        #expect(s.contains("\"path\""))
        #expect(s.contains("/repo"))
    }
}
