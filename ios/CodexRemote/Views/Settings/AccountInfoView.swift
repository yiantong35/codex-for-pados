import SwiftUI

/// 账户只读渲染的共享小视图（ipad-settings-page 设计 D4）：
/// 输入 account/usage/rateLimits，产出展示行——纯展示、无数据拉取，供设置页账户分区
/// 与（Change B 后的）环境面板复用，避免双份维护。
struct AccountInfoView: View {
    @Environment(\.locale) private var locale
    let account: Account?
    let usage: AccountTokenUsageSummary?
    let rateLimits: RateLimitSnapshot?

    enum Row: Equatable {
        case notSignedIn
        case email(String)
        case plan(String)
        case kind(String)
        case lifetime(String)
        case rateUsed(String)
        case rateReset(String)
    }

    static func rows(account: Account?,
                     usage: AccountTokenUsageSummary?,
                     rateLimits: RateLimitSnapshot?,
                     locale: Locale = LocaleManager.currentLocale) -> [Row] {
        var rows: [Row] = []
        switch account {
        case .chatgpt(let email, let planType):
            rows.append(.email(email))
            rows.append(.plan(planType))
        case .apiKey:        rows.append(.kind("API Key"))
        case .amazonBedrock: rows.append(.kind("Amazon Bedrock"))
        case nil:
            // 未登录：仅当已有用量/限额（混合态，账户未到但数据先到）才追加身份占位行，
            // 避免"只见用量不知归属"。三者全 nil 时保持空数组，走 body 的 settings.account.empty 空态。
            if usage != nil || rateLimits != nil {
                rows.append(.notSignedIn)
            }
        }
        if let life = usage?.lifetimeTokens {
            rows.append(.lifetime("\(life)"))
        }
        if let w = rateLimits?.primary {
            rows.append(.rateUsed(String(format: "%.0f%%", locale: locale, w.usedPercent)))
            if let r = w.resetsAt {
                rows.append(.rateReset(Self.reset(r, locale: locale)))
            }
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(account: account, usage: usage, rateLimits: rateLimits, locale: locale)
        if rows.isEmpty {
            Text("settings.account.empty").foregroundStyle(.secondary)
        } else {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                labeled(row)
            }
        }
    }

    @ViewBuilder private func labeled(_ row: Row) -> some View {
        switch row {
        case .notSignedIn:     Text("settings.account.none").foregroundStyle(.secondary)
        case .email(let v):    LabeledContent("env.account.email", value: v)
        case .plan(let v):     LabeledContent("env.account.plan", value: v)
        case .kind(let v):     LabeledContent("env.account", value: v)
        case .lifetime(let v): LabeledContent("env.usage.lifetime", value: v)
        case .rateUsed(let v): LabeledContent("env.rate.used", value: v)
        case .rateReset(let v):LabeledContent("env.rate.reset", value: v)
        }
    }

    static func reset(_ ts: Double, locale: Locale = LocaleManager.currentLocale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        return formatter.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}
