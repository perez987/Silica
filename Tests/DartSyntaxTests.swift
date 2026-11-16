import Foundation

@main
struct DartSyntaxTests {
    static func main() {
        precondition(SyntaxLanguage(url: URL(fileURLWithPath: "/tmp/example.DART")) == .dart)
        precondition(SyntaxLanguage(fenceName: "Dart") == .dart)
        precondition(SyntaxLanguage.dart.lineComment == "//")

        let literals = [
            "'single\\'quoted'",
            "\"double\\\"quoted\"",
            "r'raw\\'",
            "r\"raw\\\"",
            "'''multi\nline'''",
            "\"\"\"multi\nline\"\"\"",
            "'''escaped \\''' still string'''",
            "\"\"\"escaped \\\"\"\" still string\"\"\"",
            "r'''raw \\'''",
            "r\"\"\"raw \\\"\"\"",
        ]
        for literal in literals {
            let source = literal + " // comment"
            let tokens = SyntaxLanguage.dart.tokenizer.tokenize(source as NSString)
            let length = (literal as NSString).length
            precondition(tokens.contains { $0.kind == .string && $0.range == NSRange(location: 0, length: length) }, literal)
            precondition(tokens.contains { $0.kind == .comment && $0.range.location == length + 1 }, literal)
        }

        let source = "@override final int count = 42; // comment" as NSString
        let tokens = SyntaxLanguage.dart.tokenizer.tokenize(source)
        for (text, kind) in [("@override", TokenKind.attribute), ("final", .keyword), ("int", .type),
                             ("42", .number), ("// comment", .comment)] {
            let range = source.range(of: text)
            precondition(tokens.contains { $0.kind == kind && $0.range == range }, text)
        }
    }
}
