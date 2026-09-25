import UIKit

/// 作品フォルダ内の cover_custom.jpg を表紙として使う(ユーザー差し替え用)。
enum CoverStore {
    static func customPath(_ storagePath: String?) -> String? {
        guard let storagePath, !storagePath.isEmpty else { return nil }
        return storagePath + "/cover_custom.jpg"
    }

    static func customImage(_ storagePath: String?) -> UIImage? {
        guard let p = customPath(storagePath),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return UIImage(contentsOfFile: p)
    }

    static func save(_ image: UIImage, storagePath: String?) {
        guard let p = customPath(storagePath) else { return }
        let dir = (p as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let maxW: CGFloat = 1200
        let out: UIImage
        if image.size.width > maxW {
            let size = CGSize(width: maxW, height: image.size.height * maxW / image.size.width)
            out = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            out = image
        }
        try? out.jpegData(compressionQuality: 0.9)?.write(to: URL(fileURLWithPath: p))
    }
}
