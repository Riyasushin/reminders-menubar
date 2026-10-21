import Foundation

extension String {
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private final class LinkMatchCache: NSObject {
        let matches: [NSTextCheckingResult]
        init(_ matches: [NSTextCheckingResult]) { self.matches = matches }
    }

    private final class AttributedLinkCache: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    // Link detection scans the whole string. Rows rebuild title and notes on every
    // SwiftUI refresh, so keep results for strings we have already scanned.
    private static let linkMatchCache: NSCache<NSString, LinkMatchCache> = {
        let cache = NSCache<NSString, LinkMatchCache>()
        cache.countLimit = 500
        return cache
    }()

    private static let attributedLinkCache: NSCache<NSString, AttributedLinkCache> = {
        let cache = NSCache<NSString, AttributedLinkCache>()
        cache.countLimit = 500
        return cache
    }()

    subscript(safe offset: Int) -> String? {
        guard offset >= 0, offset < endIndex.utf16Offset(in: self) else {
            return nil
        }
        
        let offsetIndex = Index(utf16Offset: offset, in: self)
        return String(self[offsetIndex])
    }
    
    func substring(in nsRange: NSRange) -> String {
        guard let range = Range(nsRange, in: self) else {
            return ""
        }
        
        return String(self[range])
    }
    
    func toDetectedLinkAttributedString() -> AttributedString {
        let cacheKey = self as NSString
        if let cached = Self.attributedLinkCache.object(forKey: cacheKey) {
            return cached.value
        }

        let attributedString = NSMutableAttributedString(string: self)
        for match in detectedLinkMatches() {
            if let url = match.url {
                attributedString.addAttribute(.link, value: url, range: match.range)
            }
        }

        let value = AttributedString(attributedString)
        Self.attributedLinkCache.setObject(AttributedLinkCache(value), forKey: cacheKey)
        return value
    }

    func detectedUrls() -> [URL] {
        detectedLinkMatches().compactMap(\.url)
    }

    private func detectedLinkMatches() -> [NSTextCheckingResult] {
        let cacheKey = self as NSString
        if let cached = Self.linkMatchCache.object(forKey: cacheKey) {
            return cached.matches
        }

        let range = NSRange(startIndex..., in: self)
        let matches = Self.linkDetector?.matches(in: self, options: [], range: range) ?? []
        Self.linkMatchCache.setObject(LinkMatchCache(matches), forKey: cacheKey)
        return matches
    }
}
