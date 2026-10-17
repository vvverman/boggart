#if os(macOS)
import Foundation
@objc public protocol BoggartServiceProtocol {
    func perform(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
#endif
