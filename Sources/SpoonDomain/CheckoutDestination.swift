import Foundation

public enum CheckoutDestination {
    public static func suggestedFolderName(for repositoryURL: URL) -> String? {
        let name = repositoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidFolderName(name) ? name : nil
    }

    public static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
