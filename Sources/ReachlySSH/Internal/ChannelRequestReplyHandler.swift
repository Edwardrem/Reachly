import NIOCore
import NIOSSH

/// Waits for the server's answer to a channel request sent with want-reply: succeeds the promise on
/// SSH_MSG_CHANNEL_SUCCESS and fails it on SSH_MSG_CHANNEL_FAILURE, or when the channel errors or closes first.
/// Writing the request completes when it is sent; only this tells whether the server accepted it.
///
/// `@unchecked Sendable`: NIO calls a handler only on its channel's event loop, and `completed` is touched nowhere
/// else, so it is never accessed from two threads.
final class ChannelRequestReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    /// The server answered SSH_MSG_CHANNEL_FAILURE.
    struct Refused: Error {}

    private let promise: EventLoopPromise<Void>
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: complete(.success(()))
        case is ChannelFailureEvent: complete(.failure(Refused()))
        default: break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(ChannelError.inputClosed))
        context.fireChannelInactive()
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        promise.completeWith(result)
    }
}
