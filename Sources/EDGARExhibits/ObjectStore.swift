import Foundation
import GoogleCloudStorage

/// Minimal storage boundary so `ExhibitScraper`, `CorpusCatalog`, and HTTP routes work identically against GCS or tests.
protocol ObjectStore: Sendable {
    var bucket: String { get }
    func write(_ data: Data, to objectPath: String, contentType: String) async throws
    func read(_ objectPath: String) async throws -> (data: Data, contentType: String)
    func readCoverPrefix(_ objectPath: String) async throws -> Data
    func delete(_ objectPath: String) async throws
    func listSubprefixes(under prefix: String) async throws -> [String]
    func listObjectNames(under prefix: String) async throws -> [String]
}

extension ObjectStore {
    func readCoverPrefix(_ objectPath: String) async throws -> Data {
        try await read(objectPath).data
    }
}

/// Reads, writes, and lists scraped filings, exhibits, SEC metadata, and JSON manifests in Google Cloud Storage.
struct GCSObjectStore: ObjectStore {
    let bucket: String
    private let client: StorageClient
    private let controlClient: StorageControlClient

    init(bucket: String, client: StorageClient, controlClient: StorageControlClient) {
        self.bucket = bucket
        self.client = client
        self.controlClient = controlClient
    }

    private var bucketResourceName: String {
        bucket.hasPrefix("projects/_/buckets/") ? bucket : "projects/_/buckets/\(bucket)"
    }

    func write(_ data: Data, to objectPath: String, contentType: String) async throws {
        let options = WriteObjectOptions().with {
            $0.idempotent = true
            // Upload filings/exhibits under 32 MB in a single HTTP request instead of 2-step resumable sessions.
            $0.resumableUploadThreshold = 32 * 1024 * 1024
            $0.metadata = WriteObjectMetadata().with { meta in
                meta.contentType = contentType
            }
        }
        _ = try await client.writeObject(
            BytesSource(data: data),
            to: bucket,
            as: objectPath,
            options: options
        )
    }

    func read(_ objectPath: String) async throws -> (data: Data, contentType: String) {
        let handle = client.readObject(from: bucket, object: objectPath)
        let metadata = try await handle.metadata
        var data = Data()
        for try await chunk in handle.body {
            data.append(chunk.data)
        }
        return (data, metadata.contentType ?? "application/octet-stream")
    }

    /// Streams only the front of a Form S-1 `document.html` (breaking out of the gRPC stream once 1 MB past
    /// `</ix:header>` or 1.2 MB without Inline XBRL has arrived) so 20–40 MB financial statement tables at
    /// the back of the registration statement are never transferred.
    func readCoverPrefix(_ objectPath: String) async throws -> Data {
        let handle = client.readObject(from: bucket, object: objectPath)
        var data = Data()
        data.reserveCapacity(1_300_000)
        let ixOpen = Array("<ix:header".utf8)
        let ixClose = Array("</ix:header>".utf8)
        var checkedForIXOpen = false
        var hasIXHeader = false
        var ixCloseEndOffset: Int?

        for try await chunk in handle.body {
            let prevLen = data.count
            data.append(chunk.data)

            if !checkedForIXOpen && data.count >= 120_000 {
                checkedForIXOpen = true
                hasIXHeader = CoverPageExtractor.findCaseInsensitiveASCII(ixOpen, in: data, range: 0..<min(data.count, 350_000)) != nil
            }

            if !hasIXHeader && checkedForIXOpen && data.count >= 1_100_000 {
                break
            }

            if hasIXHeader {
                if ixCloseEndOffset == nil {
                    let scanStart = max(0, prevLen - ixClose.count)
                    if let found = CoverPageExtractor.findCaseInsensitiveASCII(ixClose, in: data, range: scanStart..<data.count) {
                        ixCloseEndOffset = found + ixClose.count
                    }
                }
                if let closeEnd = ixCloseEndOffset, data.count >= closeEnd + 1_000_000 {
                    break
                }
                if data.count >= 5_500_000 {
                    break
                }
            }
        }
        return data
    }

    func delete(_ objectPath: String) async throws {
        let request = DeleteObjectRequest().with {
            $0.bucket = bucketResourceName
            $0.object = objectPath
        }
        try await controlClient.deleteObject(request: request)
    }

    func listSubprefixes(under prefix: String) async throws -> [String] {
        let normalized = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : "\(prefix)/"
        var prefixes: [String] = []
        var pageToken = ""
        repeat {
            let token = pageToken
            let request = ListObjectsRequest().with {
                $0.parent = bucketResourceName
                $0.prefix = normalized
                $0.delimiter = "/"
                $0.pageSize = 1000
                $0.pageToken = token
            }
            let response = try await controlClient.listObjects(request: request)
            prefixes.append(contentsOf: response.prefixes)
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty
        return prefixes
    }

    func listObjectNames(under prefix: String) async throws -> [String] {
        var names: [String] = []
        var pageToken = ""
        repeat {
            let token = pageToken
            let request = ListObjectsRequest().with {
                $0.parent = bucketResourceName
                $0.prefix = prefix
                $0.pageSize = 1000
                $0.pageToken = token
            }
            let response = try await controlClient.listObjects(request: request)
            names.append(contentsOf: response.objects.map { $0.name })
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty
        return names
    }
}
