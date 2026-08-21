import OSLog

/// 临时诊断：定位「点扫码/粘贴后配对弹窗自动收回」的真因。
/// 全部日志走 category=pairing-diag，Console.app 过滤 `subsystem:com.tangyujie.codexremote category:pairing-diag` 即可看全链路。
/// 定位后整文件连同各处 PairingDiag.log(...) 调用一并删除。
enum PairingDiag {
    static let log = Logger(subsystem: "com.tangyujie.codexremote", category: "pairing-diag")
}
