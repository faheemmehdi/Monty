import Foundation

/// The app used to be called MyWispr. Brings over its data the first time Monty runs,
/// so the dictionary and settings carry over to the new name.
enum Migration {
    private static let oldBundleID = "com.faheemmehdi.mywispr"
    private static let settingKeys = ["outputMode", "microphoneUID", "keepMicWarm", "modelMemory", "loadModelAtStart"]

    static func fromMyWispr() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("MyWispr")
        let newFolder = support.appendingPathComponent("Monty")
        if fm.fileExists(atPath: oldFolder.path), !fm.fileExists(atPath: newFolder.path) {
            try? fm.moveItem(at: oldFolder, to: newFolder)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromMyWispr") else { return }
        if let old = UserDefaults(suiteName: oldBundleID) {
            for key in settingKeys {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "migratedFromMyWispr")
    }
}
