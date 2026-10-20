import Foundation

enum TokenEstimator {
    /// 粗略Estimated: Medium文约 1 字 ≈ 1 token, 英文/数字/标点约 4 字符 ≈ 1 token.
    /// 混合经验值取 chars / 3.5.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / 3.5).rounded())
    }
}

extension Int {
    var formatted: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}