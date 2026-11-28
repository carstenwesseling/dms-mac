import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision
import ZIPFoundation

/// Liest Text aus Dateien: PDF, Word, Excel, PowerPoint, Text/Code, RTF und per OCR aus Bildern.
/// Alles läuft lokal auf dem Mac.
enum TextExtractor {
    struct Result {
        var text: String
        var method: String
    }

    static let maxFileSize: Int64 = 200 * 1024 * 1024
    static let maxTextLength = 1_000_000

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]
    static let plainTextExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "log", "json", "xml", "yaml", "yml", "html", "htm", "css",
        "swift", "py", "js", "ts", "java", "c", "h", "cpp", "m", "rb", "go", "rs", "sh", "sql", "php", "kt", "ini", "conf",
    ]
    static let attributedStringExtensions: Set<String> = ["doc", "rtf", "rtfd", "odt", "wordml"]

    /// Ob ein Dateityp überhaupt ausgewertet wird.
    static func supports(ext: String) -> Bool {
        let e = ext.lowercased()
        return e == "pdf" || e == "docx" || e == "xlsx" || e == "pptx"
            || imageExtensions.contains(e) || plainTextExtensions.contains(e) || attributedStringExtensions.contains(e)
    }

    static func extract(from url: URL, ext: String) throws -> Result? {
        let e = ext.lowercased()
        let text: String
        let method: String

        switch e {
        case "pdf":
            let pdf = try extractPDF(url)
            text = pdf.0
            method = pdf.1
        case "docx":
            text = try zipXMLText(url, entries: { $0 == "word/document.xml" || $0.hasPrefix("word/header") || $0.hasPrefix("word/footer") })
            method = "docx"
        case "xlsx":
            text = try zipXMLText(url, entries: { $0 == "xl/sharedStrings.xml" || ($0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml")) })
            method = "xlsx"
        case "pptx":
            text = try zipXMLText(url, entries: { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") })
            method = "pptx"
        case _ where attributedStringExtensions.contains(e):
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            method = e
        case _ where plainTextExtensions.contains(e):
            text = try readPlainText(url, html: e == "html" || e == "htm")
            method = "text"
        case _ where imageExtensions.contains(e):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            // Jedes Bild erst kurz an einer kleinen Vorschau prüfen, ob Text zu sehen ist (Schild, Dokument,
            // Screenshot). Die gründliche Erkennung ist teuer und läuft in Apples Vision nacheinander,
            // deshalb nur, wenn wirklich Text da ist. Bei Kamerafotos reicht meist das eingebettete
            // Vorschaubild (wenige KB statt mehrerer MB), das ist vor allem auf dem NAS viel schneller.
            let preview = (isCameraPhoto(source) ? embeddedPreview(source) : nil) ?? loadImage(source, maxPixel: 1200)
            guard let preview else { return nil }
            let small = max(preview.width, preview.height) < 600
            let quick = try OCR.recognize(preview, fast: !small)
            guard small ? OCR.mightContainText(quick) : OCR.looksLikeText(quick) else {
                return Result(text: "", method: "foto")
            }
            guard let image = loadImage(source, maxPixel: 2000) else { return nil }
            text = try OCR.recognize(image)
            method = "ocr"
        default:
            return nil
        }

        let clean = normalize(text)
        return Result(text: String(clean.prefix(maxTextLength)), method: method)
    }

    // MARK: PDF

    private static func extractPDF(_ url: URL) throws -> (String, String) {
        guard let doc = PDFDocument(url: url) else { throw ExtractionError.unreadable }
        let text = doc.string ?? ""
        let pages = max(doc.pageCount, 1)
        // Wenig Text pro Seite: vermutlich ein Scan, dann OCR (bis 30 Seiten)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count / pages < 40 {
            var ocrText: [String] = []
            for index in 0..<min(doc.pageCount, 30) {
                guard let page = doc.page(at: index), let image = render(page) else { continue }
                ocrText.append(try OCR.recognize(image))
            }
            let joined = ocrText.joined(separator: "\n\n")
            if !joined.isEmpty { return (joined, "pdf-ocr") }
        }
        return (text, "pdf")
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Office (ZIP mit XML)

    private static func zipXMLText(_ url: URL, entries include: (String) -> Bool) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [String] = []
        let selected = archive.filter { include($0.path) }.sorted { naturalLess($0.path, $1.path) }
        for entry in selected {
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { chunk in data.append(chunk) }
            if let xml = String(data: data, encoding: .utf8) {
                parts.append(XMLText.strip(xml))
            }
        }
        return parts.joined(separator: "\n")
    }

    /// sheet2 vor sheet10
    private static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    // MARK: Text

    private static func readPlainText(_ url: URL, html: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return html ? XMLText.strip(text) : text
    }

    // MARK: Bilder

    static func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return loadImage(source, maxPixel: maxPixel)
    }

    static func loadImage(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Eingebettetes Vorschaubild (EXIF) ohne das ganze Bild zu lesen; nil, wenn keins vorhanden ist.
    static func embeddedPreview(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              max(image.width, image.height) >= 120 else { return nil }
        return image
    }

    /// Foto aus einer Kamera oder einem Handy (Hersteller oder Belichtungsdaten in den Metadaten).
    /// Screenshots, Scans ohne Kameradaten und Grafiken haben das nicht und werden immer voll gelesen.
    static func isCameraPhoto(_ source: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let comment = exif[kCGImagePropertyExifUserComment] as? String, comment.localizedCaseInsensitiveContains("screenshot") {
            return false
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return tiff[kCGImagePropertyTIFFMake] != nil || exif[kCGImagePropertyExifExposureTime] != nil
            || exif[kCGImagePropertyExifFNumber] != nil
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ExtractionError: Error {
        case unreadable
    }
}

/// Texterkennung mit Apples Vision-Framework (lokal).
enum OCR {
    static func recognize(_ image: CGImage, fast: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = !fast
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Großzügige Prüfung für kleine Vorschaubilder: schon ein erkanntes Wort reicht für die gründliche Erkennung.
    static func mightContainText(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.count >= 3 }
    }

    /// Ob die schnelle Erkennung echten Text gefunden hat und nicht nur ein paar zufällige Zeichen.
    static func looksLikeText(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }
        return words.count >= 3 && words.reduce(0) { $0 + $1.count } >= 15
    }
}

/// Entfernt XML/HTML-Tags und behält Absätze und Zellen als Zeilen.
enum XMLText {
    static func strip(_ xml: String) -> String {
        var s = xml
        // Absatz-, Zeilen- und Zellgrenzen als Zeilenumbruch
        s = s.replacingOccurrences(of: "</(w:p|a:p|p|div|tr|li|h[1-6]|si|row)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(w:br|w:tab|br)[^>]*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(c|td|th)>", with: " ", options: [.regularExpression, .caseInsensitive])
        // Skripte und Styles in HTML entfernen
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        // alle übrigen Tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(s)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"]
        for (k, v) in named where k != "&amp;" { out = out.replacingOccurrences(of: k, with: v) }
        // numerische Entities wie &#228; oder &#xE4;
        let regex = try! NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            let num = ns.substring(with: match.range(at: 2))
            if let code = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
