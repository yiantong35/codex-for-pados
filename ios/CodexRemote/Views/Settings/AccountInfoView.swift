import SwiftUI

/// 账户只读渲染的共享小视图（ipad-settings-page 设计 D4）：
/// 输入 account/usage/rateLimits，产出展示行——纯展示、无数据拉取，供设置页账户分区
/// 与（Change B 后的）环境面板复用，避免双份维护。
struct AccountInfoView: View {
    let account: Account?
    let usage: AccountTokenUsageSummary?
    let rateLimits: RateLimitSnapshot?

    enum Row: Equatable {
        case email(String)
        case plan(String)
        case kind(String)
        case lifetime(String)
        case rateUsed(String)
        case rateReset(String)
    }

    static func rows(account: Account?,
                     usage: AccountTokenUsageSummary?,
                     rateLimits: RateLimitSnapshot?) -> [Row] {
        var rows: [Row] = []
        switch account {
        case .chatgpt(let email, let planType):
            rows.append(.email(email))
            rows.append(.plan(planType))
        case .apiKey:        rows.append(.kind("API Key"))
        case .amazonBedrock: rows.append(.kind("Amazon Bedrock"))
        case nil:            break
        }
        if let life = usage?.lifetimeTokens {
            rows.append(.lifetime("\(life)"))
        }
        if let w = rateLimits?.primary {
            rows.append(.rateUsed(String(format: "%.0f%%", w.usedPercent)))
            if let r = w.resetsAt {
                rows.append(.rateReset(Self.reset(r)))
            }
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(account: account, usage: usage, rateLimits: rateLimits)
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
        case .email(let v):    LabeledContent("env.account.email", value: v)
        case .plan(let v):     LabeledContent("env.account.plan", value: v)
        case .kind(let v):     LabeledContent("env.account", value: v)
        case .lifetime(let v): LabeledContent("env.usage.lifetime", value: v)
        case .rateUsed(let v): LabeledContent("env.rate.used", value: v)
        case .rateReset(let v):LabeledContent("env.rate.reset", value: v)
        }
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()
    static func reset(_ ts: Double) -> String {
        relativeFormatter.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}
