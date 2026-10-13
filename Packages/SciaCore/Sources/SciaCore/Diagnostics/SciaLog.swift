public import os

/// アプリのログ。違和感レポートはこのsubsystemのログを集める。
public enum SciaLog {
    public static let subsystem = "net.mizle.scia"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
