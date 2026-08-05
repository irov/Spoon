import Foundation

public enum Redactor {
    private static let sensitiveOptionNames = [
        "--password", "--username", "--config-option", "--pin", "--passphrase"
    ]

    public static func command(executable: URL, arguments: [String]) -> String {
        var sanitized: [String] = []
        var redactNext = false

        for argument in arguments {
            if redactNext {
                sanitized.append("<redacted>")
                redactNext = false
                continue
            }

            if sensitiveOptionNames.contains(argument) {
                sanitized.append(argument)
                redactNext = true
                continue
            }

            if sensitiveOptionNames.contains(where: { argument.hasPrefix("\($0)=") }) {
                let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
                sanitized.append("\(option)=<redacted>")
                continue
            }

            sanitized.append(redactEmbeddedCredentials(in: argument))
        }

        return ([executable.path] + sanitized).map(shellDisplayQuote).joined(separator: " ")
    }

    public static func text(_ input: String) -> String {
        var output = redactEmbeddedCredentials(in: input)
        let patterns = [
            #"(?i)(password|passphrase|authorization|proxy-authorization)\s*[:=]\s*[^\s\r\n]+"#,
            #"(?i)(bearer|basic)\s+[A-Za-z0-9._~+\/-]+=*"#,
            #"(?i)-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(in: output, range: range, withTemplate: "<redacted>")
        }
        return output
    }

    private static func redactEmbeddedCredentials(in input: String) -> String {
        guard var components = URLComponents(string: input),
              components.user != nil || components.password != nil else {
            return input
        }
        components.user = components.user.map { _ in "<redacted>" }
        components.password = components.password.map { _ in "<redacted>" }
        return components.string ?? "<redacted-url>"
    }

    private static func shellDisplayQuote(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) }) else {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
