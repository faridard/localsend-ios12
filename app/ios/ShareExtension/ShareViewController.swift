//
//  ShareViewController.swift
//  ShareExtension
//
//  iOS 12 compatible share extension for LocalSend.
//  It writes shared files into the App Group container and hands the app a
//  ShareKey through the host URL scheme, matching the format used by the
//  share_handler Flutter plugin.
//

import UIKit
import MobileCoreServices
import Photos

final class ShareViewController: UIViewController {

    private let appGroupId = "group.com.faridard.localsend"
    private let shareKey = "ShareKey"
    private let hostScheme = "ShareMedia-com.faridard.localsend"
    private let hostBundleId = "com.faridard.localsend"

    private var providers: [NSItemProvider] = []
    private var attachmentDicts: [[String: Any]] = []
    private var textParts: [String] = []
    private var nextIndex = 0
    private var started = false
    private var finished = false
    private var failed = false

    private var spinner: UIActivityIndicatorView!
    private var statusLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(white: 0.0, alpha: 0.35)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Preparing..."
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        begin()
    }

    private func begin() {
        guard let context = extensionContext else {
            finish()
            return
        }

        var collected: [NSItemProvider] = []
        for case let item as NSExtensionItem in context.inputItems {
            if let attachments = item.attachments {
                collected.append(contentsOf: attachments)
            }
        }
        providers = collected
        NSLog("[LocalSendShare] begin: providers=%d", providers.count)

        if providers.isEmpty {
            for case let item as NSExtensionItem in context.inputItems {
                if let text = item.attributedContentText?.string, !text.isEmpty {
                    textParts.append(text)
                }
            }
            finish()
            return
        }

        nextIndex = 0
        processNext()
    }

    private func processNext() {
        if nextIndex >= providers.count {
            finish()
            return
        }
        let provider = providers[nextIndex]
        nextIndex += 1
        process(provider) { [weak self] in
            DispatchQueue.main.async {
                self?.processNext()
            }
        }
    }

    private func process(_ provider: NSItemProvider, completion: @escaping () -> Void) {
        if provider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
            load(provider, typeIdentifier: kUTTypeImage as String) { [weak self] item, error in
                self?.handleImage(item, error: error)
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String) {
            load(provider, typeIdentifier: kUTTypeMovie as String) { [weak self] item, error in
                self?.handleFileItem(item, error: error, type: 1, fallbackExtension: "mov")
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeAudio as String) {
            load(provider, typeIdentifier: kUTTypeAudio as String) { [weak self] item, error in
                self?.handleFileItem(item, error: error, type: 2, fallbackExtension: "m4a")
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String) {
            load(provider, typeIdentifier: kUTTypeFileURL as String) { [weak self] item, error in
                self?.handleFileItem(item, error: error, type: 3, fallbackExtension: "dat")
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeURL as String) {
            load(provider, typeIdentifier: kUTTypeURL as String) { [weak self] item, error in
                self?.handleTextItem(item, error: error)
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeText as String) {
            load(provider, typeIdentifier: kUTTypeText as String) { [weak self] item, error in
                self?.handleTextItem(item, error: error)
                completion()
            }
        } else if provider.hasItemConformingToTypeIdentifier(kUTTypeData as String) {
            load(provider, typeIdentifier: kUTTypeData as String) { [weak self] item, error in
                self?.handleFileItem(item, error: error, type: 3, fallbackExtension: "dat")
                completion()
            }
        } else {
            completion()
        }
    }

    private func load(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        completion: @escaping (NSSecureCoding?, Error?) -> Void
    ) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
            completion(item, error)
        }
    }

    // MARK: - Item handlers

    private func handleImage(_ item: NSSecureCoding?, error: Error?) {
        if error != nil {
            markFailed()
            return
        }

        if let url = item as? URL {
            if let dict = storeFile(at: url, type: 0, fallbackExtension: "jpg") {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else if let image = item as? UIImage {
            if let data = image.pngData(),
               let dict = storeData(data, type: 0, preferredExtension: "png") {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else if let data = item as? Data {
            if let dict = storeData(data, type: 0, preferredExtension: extensionForData(data, fallback: "jpg")) {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else {
            markFailed()
        }
    }

    private func handleFileItem(
        _ item: NSSecureCoding?,
        error: Error?,
        type: Int,
        fallbackExtension: String
    ) {
        if error != nil {
            markFailed()
            return
        }

        if let url = item as? URL {
            if let dict = storeFile(at: url, type: type, fallbackExtension: fallbackExtension) {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else if let data = item as? Data {
            if let dict = storeData(data, type: type, preferredExtension: extensionForData(data, fallback: fallbackExtension)) {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else if let image = item as? UIImage {
            if let data = image.pngData(),
               let dict = storeData(data, type: 0, preferredExtension: "png") {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else {
            markFailed()
        }
    }

    private func handleTextItem(_ item: NSSecureCoding?, error: Error?) {
        if error != nil {
            markFailed()
            return
        }

        if let string = item as? String {
            appendText(string)
        } else if let url = item as? URL {
            appendText(url.absoluteString)
        } else if let attributed = item as? NSAttributedString {
            appendText(attributed.string)
        } else if let data = item as? Data {
            if let string = String(data: data, encoding: .utf8) {
                appendText(string)
            } else if let dict = storeData(data, type: 3, preferredExtension: "dat") {
                appendAttachment(dict)
            } else {
                markFailed()
            }
        } else {
            markFailed()
        }
    }

    // MARK: - Storage

    private var groupContainer: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private func appendAttachment(_ dict: [String: Any]) {
        DispatchQueue.main.async {
            self.attachmentDicts.append(dict)
        }
    }

    private func appendText(_ text: String) {
        DispatchQueue.main.async {
            self.textParts.append(text)
        }
    }

    private func markFailed() {
        DispatchQueue.main.async {
            self.failed = true
        }
    }

    private func storeFile(at source: URL, type: Int, fallbackExtension: String) -> [String: Any]? {
        guard let container = groupContainer else {
            NSLog("[LocalSendShare] storeFile: app group container is nil")
            return nil
        }
        let name = sanitizedFileName(source.lastPathComponent, fallbackExtension: fallbackExtension)
        let destination = uniqueDestination(in: container, fileName: name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            NSLog("[LocalSendShare] stored %@", destination.path)
            return ["path": destination.absoluteString, "type": type]
        } catch {
            NSLog("[LocalSendShare] copy failed %@: %@", source.path, error.localizedDescription)
            return nil
        }
    }

    private func storeData(_ data: Data, type: Int, preferredExtension: String) -> [String: Any]? {
        guard let container = groupContainer else {
            NSLog("[LocalSendShare] storeData: app group container is nil")
            return nil
        }
        let destination = container.appendingPathComponent(UUID().uuidString + "." + preferredExtension)
        do {
            try data.write(to: destination, options: .atomic)
            NSLog("[LocalSendShare] stored data %@", destination.path)
            return ["path": destination.absoluteString, "type": type]
        } catch {
            NSLog("[LocalSendShare] write failed %@: %@", destination.path, error.localizedDescription)
            return nil
        }
    }

    private func sanitizedFileName(_ raw: String, fallbackExtension: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty || name == "." || name == ".." {
            name = UUID().uuidString + "." + fallbackExtension
        }
        if (name as NSString).pathExtension.isEmpty {
            name += "." + fallbackExtension
        }
        return name
    }

    private func uniqueDestination(in container: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = container.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            candidate = container.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    private func extensionForData(_ data: Data, fallback: String) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "gif"
        }
        if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            if bytes.count >= 12 {
                let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
                if brand == "qt  " {
                    return "mov"
                }
                if brand.hasPrefix("mp4") || brand == "isom" || brand == "iso2" || brand == "avc1" {
                    return "mp4"
                }
                if brand == "heic" || brand == "heix" || brand == "mif1" || brand == "msf1" {
                    return "heic"
                }
            }
            return fallback
        }
        return fallback
    }

    // MARK: - Finish

    private func finish() {
        guard !finished else { return }
        finished = true
        spinner.stopAnimating()

        if attachmentDicts.isEmpty && textParts.isEmpty {
            showErrorAndComplete("Nothing could be shared. Please try again.")
            return
        }

        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("[LocalSendShare] UserDefaults suite unavailable")
            showErrorAndComplete("App Group is unavailable on this build.")
            return
        }

        let media: [String: Any] = [
            "attachments": attachmentDicts,
            "content": textParts.joined(separator: "\n"),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: media, options: [])
            defaults.set(data, forKey: shareKey)
            defaults.synchronize()
            NSLog("[LocalSendShare] queued %d attachment(s), %d text part(s), group=%@", attachmentDicts.count, textParts.count, groupContainer?.path ?? "nil")
        } catch {
            NSLog("[LocalSendShare] json failed: %@", error.localizedDescription)
            showErrorAndComplete("Could not prepare the shared item.")
            return
        }

        openHostApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func openHostApp() {
        guard let url = URL(string: "\(hostScheme)://\(hostBundleId)?key=\(shareKey)") else {
            NSLog("[LocalSendShare] invalid host URL")
            return
        }
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                NSLog("[LocalSendShare] openURL via %@", String(describing: type(of: current)))
                return
            }
            responder = current.next
        }
        NSLog("[LocalSendShare] no responder handled openURL, trying extensionContext.open")
        extensionContext?.open(url, completionHandler: nil)
    }

    private func showErrorAndComplete(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message

        let alert = UIAlertController(title: "LocalSend", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        present(alert, animated: true, completion: nil)
    }
}
