import UIKit
import UniformTypeIdentifiers

/// Share extension — hand a TOC URL to the shelf and fetch it in place.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.964, green: 0.952, blue: 0.925, alpha: 1)

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = UIColor(red: 0.13, green: 0.12, blue: 0.1, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        handleIncoming()
    }

    private func handleIncoming() {
        nc_http_apple_install()
        let root = sharedLibraryRoot().path
        _ = callCore { novel_core_set_root_dir(root) }

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first
        else {
            finish("Nothing to save.")
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                guard let self, let url = data as? URL else {
                    self?.finish("Could not read the shared URL.")
                    return
                }
                self.import(url: url)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] data, _ in
                guard let self, let text = data as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    self?.finish("Could not read the shared text.")
                    return
                }
                self.import(url: url)
            }
        } else {
            finish("Unsupported share payload.")
        }
    }

    private func import(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let slug = url.absoluteString
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let dir = self?.sharedLibraryRoot()
                .appendingPathComponent(slug, isDirectory: true).path ?? ""
            let options = "{\"url\":\"\(url.absoluteString)\",\"output_dir\":\"\(dir)\"}"
            guard let cstr = novel_core_fetch_toc(options) else {
                self?.finish("Fetch failed.")
                return
            }
            let payload = String(cString: cstr)
            novel_core_string_free(cstr)
            let ok = payload.contains("\"ok\":true")
            DispatchQueue.main.async {
                self?.finish(ok ? "Saved “\(url.host ?? url.absoluteString)” to your shelf." : "Fetch failed — check the site preset.")
            }
        }
    }

    private func callCore(_ body: () -> UnsafeMutablePointer<CChar>?) -> String? {
        guard let cstr = body() else { return nil }
        defer { novel_core_string_free(cstr) }
        return String(cString: cstr)
    }

    private func sharedLibraryRoot() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NovelLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}
