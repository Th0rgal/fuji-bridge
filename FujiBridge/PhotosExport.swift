import Foundation
import Photos

/// Adds imported photos to the Photos library, in a "Fuji Bridge" album. The file in Files (or Pictures on the
/// Mac) stays the app's own copy; Photos gets a copy of its own.
enum PhotosExport {
    static let albumName = "Fuji Bridge"

    enum Outcome: Sendable { case added, denied, failed(String) }

    /// Asks once for access. Full access lets the album be created; "add only" still puts the photo in the library.
    static func add(_ url: URL) async -> Outcome {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized:
            return await addToAlbum(url)
        case .limited:
            return await addLoose(url)
        default:
            let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if addOnly == .authorized { return await addLoose(url) }
            return .denied
        }
    }

    private static func addLoose(_ url: URL) async -> Outcome {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
            return .added
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func addToAlbum(_ url: URL) async -> Outcome {
        do {
            let album = try await album()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: .photo, fileURL: url, options: options)
                if let album, let placeholder = request.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            return .added
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The "Fuji Bridge" album, created the first time.
    private static func album() async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            return found
        }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }
}
