import Foundation

/// Lays a request's text out in fixed columns of a monospaced font, so the notch
/// shows exactly what will run. Word wrap can't: a space at a soft break vanishes,
/// and a real line break looks just like a wrap. Here a real "\n" starts a new
/// row, a row the layout had to cut is marked as a continuation, and a space at
/// either end of a row is flagged so the view can draw it.
///
/// Columns count Characters, which is exact for printable ASCII: the only text
/// Allow is offered for (`ApprovalPolicy.action`).
public enum ApprovalLayout {
    /// The narrowest column count a view may offer Allow next to.
    public static let minColumnsForAllow = 8

    /// Whether text laid out in `columns` (nil: not measured yet) is legible enough
    /// to offer Allow beside it. A view that couldn't lay its text out never offers Allow.
    public static func canOfferAllow(columns: Int?) -> Bool {
        guard let columns else { return false }
        return columns >= minColumnsForAllow
    }

    public struct Piece: Equatable, Sendable {
        public let text: String
        /// Cut from the same line as the piece before it, not started by a real "\n".
        public let continuation: Bool
        /// The first character is a space.
        public let leadingSpace: Bool
        /// The last character is a space (and not the same character as `leadingSpace`).
        public let trailingSpace: Bool

        /// `text` without the flagged edge spaces (the view draws those as marks).
        public var middle: String {
            String(text.dropFirst(leadingSpace ? 1 : 0).dropLast(trailingSpace ? 1 : 0))
        }
    }

    /// One piece per displayed row, each at most `columns` characters (at least 1).
    public static func pieces(_ text: String, columns: Int) -> [Piece] {
        let columns = max(1, columns)
        var pieces: [Piece] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let chars = Array(line)
            var start = 0
            repeat {
                let end = min(start + columns, chars.count)
                let text = String(chars[start..<end])
                pieces.append(Piece(text: text, continuation: start > 0,
                                    leadingSpace: text.first == " ",
                                    trailingSpace: text.count > 1 && text.last == " "))
                start = end
            } while start < chars.count
        }
        return pieces
    }
}
