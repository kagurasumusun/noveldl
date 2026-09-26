import UIKit
import UniformTypeIdentifiers

/// 共有された作品アドレスを本体アプリへ渡す。
/// 拡張機能の書類フォルダへ保存すると本棚に出ないため、ここでは取得しない。
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.106, green: 0.102, blue: 0.094, alpha: 1)

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = UIColor(red: 0.925, green: 0.910, blue: 0.878, alpha: 1)
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
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first
        else {
            finish("渡すものがありません")
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                guard let self, let url = data as? URL else {
                    self?.finish("共有されたアドレスを読めませんでした")
                    return
                }
                self.handOff(url)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] data, _ in
                guard let self,
                      let text = data as? String,
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    self?.finish("共有された文字を読めませんでした")
                    return
                }
                self.handOff(url)
            }
        } else {
            finish("この形式には対応していません")
        }
    }

    private func handOff(_ url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var parts = URLComponents()
            parts.scheme = "novelios"
            parts.host = "add"
            parts.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            guard let open = parts.url else {
                self.finish("アドレスを渡せませんでした")
                return
            }
            self.extensionContext?.open(open) { ok in
                self.finish(ok
                    ? "本棚に追加しています"
                    : "アプリを開けませんでした。アドレスをコピーして、本棚から追加してください。",
                    linger: ok ? 1.2 : 2.4)
            }
        }
    }

    private func finish(_ message: String, linger: TimeInterval = 1.2) {
        DispatchQueue.main.async {
            self.statusLabel.text = message
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}
