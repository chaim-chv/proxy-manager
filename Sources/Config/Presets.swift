import Foundation

/// A ready-made set of target rules for a known service. Used by onboarding
/// and the Targets editor so users can start from a sensible allow-list instead
/// of typing every domain by hand.
struct TargetPreset: Identifiable {
    let id: String
    let name: String
    let summary: String
    let rules: [TargetRule]

    var ruleCount: Int { rules.count }

    static let all: [TargetPreset] = [
        TargetPreset(
            id: "deepseek",
            name: "DeepSeek API",
            summary: "DeepSeek chat + API endpoints.",
            rules: [
                TargetRule(pattern: "deepseek.com"),
                TargetRule(pattern: "*.deepseek.com"),
            ]
        ),
        TargetPreset(
            id: "openai",
            name: "OpenAI",
            summary: "ChatGPT and the OpenAI API.",
            rules: [
                TargetRule(pattern: "openai.com"),
                TargetRule(pattern: "*.openai.com"),
                TargetRule(pattern: "chatgpt.com"),
                TargetRule(pattern: "*.chatgpt.com"),
            ]
        ),
        TargetPreset(
            id: "anthropic",
            name: "Anthropic / Claude",
            summary: "Claude and the Anthropic API.",
            rules: [
                TargetRule(pattern: "anthropic.com"),
                TargetRule(pattern: "*.anthropic.com"),
                TargetRule(pattern: "claude.ai"),
                TargetRule(pattern: "*.claude.ai"),
            ]
        ),
        TargetPreset(
            id: "gemini",
            name: "Google Gemini",
            summary: "Gemini API endpoints.",
            rules: [
                TargetRule(pattern: "generativelanguage.googleapis.com"),
                TargetRule(pattern: "*.generativelanguage.googleapis.com"),
            ]
        ),
        TargetPreset(
            id: "github",
            name: "GitHub",
            summary: "GitHub and its raw/download domains.",
            rules: [
                TargetRule(pattern: "github.com"),
                TargetRule(pattern: "*.github.com"),
                TargetRule(pattern: "githubusercontent.com"),
                TargetRule(pattern: "*.githubusercontent.com"),
            ]
        ),
        TargetPreset(
            id: "nvidia",
            name: "NVIDIA",
            summary: "NVIDIA and its API endpoints.",
            rules: [
                TargetRule(pattern: "nvidia.com"),
                TargetRule(pattern: "*.nvidia.com"),
                TargetRule(pattern: "ngc.nvidia.com"),
            ]
        ),
        TargetPreset(
            id: "whatsapp",
            name: "WhatsApp",
            summary: "WhatsApp web and media domains.",
            rules: [
                TargetRule(pattern: "whatsapp.com"),
                TargetRule(pattern: "*.whatsapp.com"),
                TargetRule(pattern: "whatsapp.net"),
                TargetRule(pattern: "*.whatsapp.net"),
            ]
        ),
    ]

    static func with(id: String) -> TargetPreset? {
        all.first { $0.id == id }
    }
}
