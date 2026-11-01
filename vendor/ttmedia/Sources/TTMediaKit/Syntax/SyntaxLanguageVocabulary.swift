// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Language family classification, shebang dialect resolution, and keyword/type tables
/// for `BackgroundSyntaxTokenizer`.
public enum SyntaxLanguageVocabulary {
    /// Extensions belonging to the POSIX / macOS Shell script syntax family.
    /// `.command` is the standard macOS Terminal launch script extension and shares the
    /// `sh` / `bash` / `zsh` / `fish` highlighting pipeline in read-only preview mode.
    public static let shellExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "command"
    ]

    /// Extensions that treat `#` as a line-comment introducer (including `#!` shebang lines).
    public static let hashCommentExtensions: Set<String> = [
        "py", "pyw", "sh", "bash", "zsh", "fish", "command",
        "rb", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "makefile", "mk", "cmake", "dockerfile", "bazel", "bzl",
        "pl", "pm", "r", "nim", "ex", "exs"
    ]

    /// Refines a shell-family extension using the first-line `#!` shebang when present,
    /// while keeping unknown/plain-text extensions strictly on their existing contract.
    public static func resolveShellShebangDialect(from leadingText: String, fallbackExt: String) -> String {
        let cleanFallback = fallbackExt.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard shellExtensions.contains(cleanFallback) else { return cleanFallback }
        guard leadingText.hasPrefix("#!") else { return cleanFallback }
        let firstLineEnd = leadingText.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? leadingText.endIndex
        let shebangLine = leadingText[..<firstLineEnd].lowercased()
        if shebangLine.contains("zsh") { return "zsh" }
        if shebangLine.contains("bash") { return "bash" }
        if shebangLine.contains("fish") { return "fish" }
        if shebangLine.contains("/sh") || shebangLine.hasSuffix(" sh") { return "sh" }
        return cleanFallback
    }

    internal struct LexerConfig: Sendable {
        let canonicalExt: String
        let keywords: Set<String>
        let builtInTypes: Set<String>
        let isHashComment: Bool
        let isShellFamily: Bool

        init(ext: String, leadingText: String = "") {
            let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            let isShell = SyntaxLanguageVocabulary.shellExtensions.contains(cleanExt)
            let resolvedExt = isShell
                ? SyntaxLanguageVocabulary.resolveShellShebangDialect(from: leadingText, fallbackExt: cleanExt)
                : cleanExt
            self.canonicalExt = resolvedExt
            self.isShellFamily = isShell
            self.keywords = SyntaxLanguageVocabulary.keywordsForExtension(resolvedExt)
            self.builtInTypes = SyntaxLanguageVocabulary.typesForExtension(resolvedExt)
            self.isHashComment = isShell || SyntaxLanguageVocabulary.hashCommentExtensions.contains(resolvedExt)
        }
    }

    private static let specialShellParameterUnits: Set<UInt16> = [64, 42, 63, 35, 36, 33, 45]
    private static let bracedParameterTerminatorUnits: Set<UInt16> = [125, 10, 13]

    /// Scans a shell variable or parameter expansion (`$VAR`, `${VAR}`, `$1`, `$@`, `$?`, `$#`, `$$`, `$!`, `$*`, `$-`).
    internal static func scanShellParameter(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int
    ) -> TokenSpan? {
        guard chars[i] == 36, i + 1 < limit else { return nil }
        let next = chars[i + 1]
        if next == 123 {
            return scanBracedShellParameter(chars, at: &i, limit: limit, baseOffset: baseOffset)
        }
        if isASCIIAlphaOrUnderscore(next) {
            return scanIdentifierShellParameter(chars, at: &i, limit: limit, baseOffset: baseOffset)
        }
        if isASCIIDigit(next) {
            return scanPositionalShellParameter(chars, at: &i, limit: limit, baseOffset: baseOffset)
        }
        if specialShellParameterUnits.contains(next) {
            let start = i
            i += 2
            return TokenSpan(range: NSRange(location: baseOffset + start, length: 2), colorType: .type)
        }
        return nil
    }

    private static func scanBracedShellParameter(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int
    ) -> TokenSpan? {
        let start = i
        var j = i + 2
        while j < limit && !bracedParameterTerminatorUnits.contains(chars[j]) {
            j += 1
        }
        guard j < limit, chars[j] == 125, j > i + 2 else { return nil }
        i = j + 1
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .type)
    }

    private static func scanIdentifierShellParameter(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int
    ) -> TokenSpan? {
        let start = i
        i += 2
        while i < limit && isASCIIAlphaNumericOrUnderscore(chars[i]) {
            i += 1
        }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .type)
    }

    private static func scanPositionalShellParameter(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int
    ) -> TokenSpan? {
        let start = i
        i += 2
        while i < limit && isASCIIDigit(chars[i]) {
            i += 1
        }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .type)
    }

    private static func isASCIIDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isASCIIAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isASCIIAlphaOrUnderscore(_ c: UInt16) -> Bool { isASCIIAlpha(c) || c == 95 }
    private static func isASCIIAlphaNumericOrUnderscore(_ c: UInt16) -> Bool { isASCIIAlphaOrUnderscore(c) || isASCIIDigit(c) }

    internal static func keywordsForExtension(_ ext: String) -> Set<String> {
        switch ext.lowercased() {
        case "sh", "bash", "zsh", "fish", "command":
            return [
                "if", "then", "elif", "else", "fi", "for", "in", "do", "done",
                "while", "until", "case", "esac", "function", "select", "time", "coproc",
                "return", "exit", "break", "continue", "export", "local", "readonly",
                "declare", "typeset", "unset", "shift", "source", "eval", "exec",
                "trap", "set", "shopt", "true", "false", "begin", "end", "switch",
                "and", "or", "not"
            ]
        case "swift":
            return [
                "let", "var", "func", "struct", "class", "enum", "actor", "protocol", "extension",
                "init", "deinit", "import", "public", "private", "fileprivate", "internal", "open",
                "guard", "if", "else", "switch", "case", "default", "for", "in", "while", "repeat",
                "return", "throw", "throws", "try", "catch", "async", "await", "self", "Self",
                "typealias", "some", "any", "weak", "unowned", "mutating", "override", "final",
                "static", "where", "as", "is", "break", "continue", "fallthrough", "defer", "true", "false", "nil"
            ]
        case "rs":
            return [
                "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "type", "match",
                "if", "else", "loop", "while", "for", "in", "return", "use", "mod", "crate",
                "super", "self", "Self", "const", "static", "async", "await", "move", "ref",
                "where", "unsafe", "dyn", "break", "continue", "true", "false", "as"
            ]
        case "py", "pyw":
            return [
                "def", "class", "import", "from", "as", "return", "if", "elif", "else",
                "for", "while", "break", "continue", "try", "except", "finally", "raise",
                "with", "async", "await", "lambda", "yield", "pass", "global", "nonlocal",
                "assert", "True", "False", "None", "in", "is", "not", "and", "or"
            ]
        case "js", "ts", "jsx", "tsx", "mjs", "cjs", "mts", "cts":
            return [
                "function", "const", "let", "var", "class", "interface", "type", "enum",
                "import", "export", "from", "as", "default", "return", "if", "else", "switch",
                "case", "for", "while", "do", "break", "continue", "try", "catch", "finally",
                "throw", "new", "this", "super", "async", "await", "yield", "typeof", "instanceof",
                "in", "of", "extends", "implements", "true", "false", "null", "undefined"
            ]
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "m", "mm":
            return [
                "auto", "break", "case", "const", "continue", "default", "do",
                "else", "enum", "extern", "for", "goto", "if", "register",
                "return", "signed", "sizeof", "static", "struct", "switch", "typedef",
                "union", "unsigned", "volatile", "while", "class", "public", "private",
                "protected", "template", "typename", "namespace", "using", "virtual", "constexpr",
                "inline", "nullptr", "true", "false", "new", "delete"
            ]
        case "go":
            return [
                "package", "import", "func", "var", "const", "type", "struct", "interface",
                "map", "chan", "select", "case", "default", "defer", "go", "return", "if",
                "else", "switch", "for", "range", "break", "continue", "fallthrough", "goto",
                "true", "false", "nil"
            ]
        case "json", "jsonc", "jsonl":
            return ["true", "false", "null"]
        default:
            return [
                "func", "function", "def", "fn", "var", "let", "const", "val", "if", "else",
                "for", "while", "return", "import", "class", "struct", "true", "false", "null", "nil"
            ]
        }
    }

    internal static func typesForExtension(_ ext: String) -> Set<String> {
        switch ext.lowercased() {
        case "rs":
            return [
                "i8", "i16", "i32", "i64", "i128", "isize",
                "u8", "u16", "u32", "u64", "u128", "usize",
                "f32", "f64", "bool", "char", "str"
            ]
        case "py", "pyw":
            return [
                "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object"
            ]
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "m", "mm":
            return [
                "int", "char", "float", "double", "void", "bool", "short", "long",
                "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                "int8_t", "int16_t", "int32_t", "int64_t", "uintptr_t", "intptr_t"
            ]
        case "go":
            return [
                "int", "int8", "int16", "int32", "int64",
                "uint", "uint8", "uint16", "uint32", "uint64",
                "float32", "float64", "string", "bool", "byte", "rune"
            ]
        case "ts", "tsx", "mts", "cts":
            return [
                "number", "string", "boolean", "any", "void", "never", "unknown"
            ]
        default:
            return []
        }
    }
}
