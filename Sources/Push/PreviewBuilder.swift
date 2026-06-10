import Foundation

/// Builds the push preview by cutting a message to ≤200 characters on a grapheme
/// (Character) boundary. `String.prefix(n)` operates on extended grapheme
/// clusters, so Korean composed characters (including NFD-decomposed jamo) never
/// break mid-cluster — the same message-boundary rule the P4 ring buffer uses.
public enum PreviewBuilder {
    public static let maxChars = 200

    public static func build(from message: String) -> String {
        if message.count <= maxChars { return message }
        return String(message.prefix(maxChars))
    }
}
