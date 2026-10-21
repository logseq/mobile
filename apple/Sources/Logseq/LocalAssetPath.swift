import Foundation
import LogseqModel

enum LocalAssetPath {
    private static let assetsDirectoryName = "Assets"

    static func storedPath(
        _ path: String,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    ) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let assetsDirectory = documentsDirectory
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == assetsDirectory else { return path }
        return assetsDirectoryName + "/" + url.lastPathComponent
    }

    static func resolve(
        _ path: String,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) -> URL? {
        guard !path.isEmpty else { return nil }

        let graphID = UserDefaults.standard.string(forKey: "logseq.selectedGraphId") ?? ""
        if !graphID.isEmpty {
            let graphDirectory = LogseqGraphLocalStorage.directoryURL(
                databasePath: documentsDirectory.appendingPathComponent("logseq.sqlite").path,
                graphID: graphID
            )
            let graphAsset = graphDirectory.appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            if fileManager.fileExists(atPath: graphAsset.path) { return graphAsset }
        }

        let storedURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : documentsDirectory.appendingPathComponent(path)
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let relocatedURL = documentsDirectory
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
            .appendingPathComponent(storedURL.lastPathComponent)
        return fileManager.fileExists(atPath: relocatedURL.path) ? relocatedURL : nil
    }

    static func resolve(
        _ path: String?,
        title: String,
        assetType: String?,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) -> URL? {
        if let path,
           let resolved = resolve(
               path,
               documentsDirectory: documentsDirectory,
               fileManager: fileManager
           ) {
            return resolved
        }

        let fileName = URL(fileURLWithPath: title).lastPathComponent
        guard !fileName.isEmpty, fileName == title else { return nil }
        let extensionFromType = assetType?
            .split(separator: "/")
            .last
            .map(String.init)?
            .lowercased()
        let recoveredFileName: String
        if URL(fileURLWithPath: fileName).pathExtension.isEmpty,
           let extensionFromType,
           !extensionFromType.isEmpty {
            recoveredFileName = fileName + "." + extensionFromType
        } else {
            recoveredFileName = fileName
        }
        let recoveredURL = documentsDirectory
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
            .appendingPathComponent(recoveredFileName)
        return fileManager.fileExists(atPath: recoveredURL.path) ? recoveredURL : nil
    }
}
