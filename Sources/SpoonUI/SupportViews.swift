import AppKit
import SwiftUI

private let supportEmailAddress = "support@wonderland-games.com"

public struct SupportView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spoon Help")
                        .font(.title2.bold())
                    Text("Native Subversion client for macOS")
                        .foregroundStyle(.secondary)
                }
            }

            Text("If you need help or found a problem, contact our support team.")

            Button(supportEmailAddress) {
                openURL(SupportMail.url())
            }
            .buttonStyle(.link)
            .accessibilityLabel("Email Spoon Support")

            HStack {
                Spacer()
                Button("Send Feedback…") {
                    openWindow(id: "spoon-feedback")
                }
                Button("Compose Email") {
                    openURL(SupportMail.url())
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

public struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var summary = ""
    @State private var details = ""
    @State private var replyAddress = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Feedback")
                        .font(.title2.bold())
                    Text("Your message will be addressed to \(supportEmailAddress).")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Brief description", text: $summary)
                TextField("Details", text: $details, axis: .vertical)
                    .lineLimit(4...8)
                TextField("Your email (optional)", text: $replyAddress)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open in Mail") {
                    openURL(SupportMail.url(summary: summary, details: details, replyAddress: replyAddress))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private enum SupportMail {
    static func url(summary: String = "", details: String = "", replyAddress: String = "") -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress

        var queryItems: [URLQueryItem] = []
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            queryItems.append(URLQueryItem(name: "subject", value: "Spoon: \(trimmedSummary)"))
        }

        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplyAddress = replyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyParts = [
            trimmedDetails,
            trimmedReplyAddress.isEmpty ? "" : "Reply email: \(trimmedReplyAddress)"
        ].filter { !$0.isEmpty }
        if !bodyParts.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: bodyParts.joined(separator: "\n\n")))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? URL(string: "mailto:\(supportEmailAddress)")!
    }
}
