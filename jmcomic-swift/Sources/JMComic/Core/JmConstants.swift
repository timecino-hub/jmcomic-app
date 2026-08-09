import Foundation

enum JmConstants {
    static let tokenSecret = "18comicAPP"
    static let dataSecret = "185Hcomic3PAPP7R"
    static let domainServerSecret = "diosfjckwpqpdfjkvnqQjsik"

    /// 会被 setting 接口返回的版本号覆盖
    nonisolated(unsafe) static var appVersion = "2.0.30"

    /// 响应里没带 scramble_id 时的兜底值。低于这个 id 的本子未加扰。
    static let defaultScrambleId = 220980
    static let scramble268850 = 268850
    static let scramble421926 = 421926

    static let userAgent = "Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36"

    /// 域名服务器：返回整页 AES 加密的最新域名列表
    static let domainServers = [
        "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt",
    ]

    /// 域名服务器不可达时的兜底
    static let fallbackDomains = [
        "www.cdnhjk.net", "www.cdngwc.cc", "www.cdngwc.net", "www.cdngwc.club",
    ]

    static let imageDomains = [
        "cdn-msp.jmapiproxy1.cc", "cdn-msp.jmapiproxy2.cc",
        "cdn-msp2.jmapiproxy2.cc", "cdn-msp3.jmapiproxy2.cc",
        "cdn-msp.jmapinodeudzn.net", "cdn-msp3.jmapinodeudzn.net",
    ]
}
