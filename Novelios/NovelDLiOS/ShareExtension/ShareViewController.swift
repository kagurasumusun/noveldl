import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resolveSharedNovelURL { [weak self] sharedURL in
            guard let self else { return }
            if let sharedURL, let appURL = Self.appURL(for: sharedURL) {
                self.extensionContext?.open(appURL) { _ in
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } else {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func resolveSharedNovelURL(completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = item as? URL
                Task { @MainActor in completion(url) }
            }
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = item as? String
                let url = text.flatMap(Self.firstURL(in:))
                Task { @MainActor in completion(url) }
            }
            return
        }

        completion(nil)
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.firstMatch(in: text, range: nsRange)?.url
    }

    private static func appURL(for sharedURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "novelios"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]
        return components.url
    }
}
