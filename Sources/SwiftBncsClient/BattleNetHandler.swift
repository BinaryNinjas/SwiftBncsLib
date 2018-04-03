import NIO
import Foundation
import SwiftBncsLib

class BattleNetHandler: ChannelInboundHandler {

    public typealias InboundIn = BncsMessage
    public typealias OutboundOut = ByteBuffer

    enum BattleNetConnectionStatus {
        case connecting
        case socketOpened
        case authorizing
        case loggingIn
        case connected
        case disconnecting
        case disconnected
    }

    var channel: Channel!

    private var state: BattleNetConnectionStatus = .disconnected {
        didSet {
            print("[BNCS] Status changed from \(oldValue) to \(state).")

            switch state {
            case .connecting:
                print("[BNCS] Connecting...")

            case .socketOpened:
                print("[BNCS] Connected to \(channel.remoteAddress!).")
                sendProtocolByteAndAuthInfo()

            case .disconnecting:
                print("[BNCS] Disconnecting..")
                let _ = channel.close(mode: .all)

            case .disconnected:
                print("[BNCS] Disconnected.")

            default:
                let _ = 0
                //                    print("[BNCS] Status changed from \(oldValue) to \(state).")
            }
        }
    }

    let clientToken = arc4random_uniform(UInt32.max)
    var serverToken: UInt32 = 0

    // MARK -

    /// Called when the `Channel` has successfully registered with its `EventLoop` to handle I/O.
    public func channelRegistered(ctx: ChannelHandlerContext) {
        channel = ctx.channel

        ctx.fireChannelRegistered()

        state = .connecting
    }

    /// Called when the `Channel` has become active, and is able to send and receive data.
    public func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()

        state = .socketOpened
    }

    /// Called when the `Channel` has become inactive and is no longer able to send and receive data`.
    public func channelInactive(ctx: ChannelHandlerContext) {
        ctx.fireChannelInactive()

        state = .disconnected
    }

    /// MARK -

    func monitorDefunctValues<T: Comparable>(value: T, expected: T, description: String) {
        if value != expected {
            print("[BNCS] Unexpected value in defunct field. Description: \(description), value: \(value).")
        }
    }

    func sendProtocolByteAndAuthInfo() {
        state = .authorizing

        var protocolByteBuffer = channel.allocator.buffer(capacity: 1)
        protocolByteBuffer.write(bytes: [1])
        let _ = channel.writeAndFlush(protocolByteBuffer)

        var composer = BncsMessageComposer()
        composer.write(0 as UInt32)
        composer.write(BncsPlatformIdentifier.IntelX86.rawValue)
        composer.write(BncsProductIdentifier.Diablo2.rawValue)
        composer.write(0x0E as UInt32)
        composer.write(BncsLanguageIdentifier.EnglishUnitedStates.rawValue)
        composer.write(0 as UInt32)
        composer.write(0 as UInt32)
        composer.write(0 as UInt32)
        composer.write(0 as UInt32)
        composer.write("USA")
        composer.write("United States")
        let authInfoMessage = composer.build(messageIdentifier: BncsMessageIdentifier.AuthInfo)
        let _ = authInfoMessage.writeToChannel(channel)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)

        processMessage(message)
    }

    func processMessage(_ message: BncsMessage) {
        var consumer = BncsMessageConsumer(message: message)

        switch consumer.message.identifier {
        case .Null:
            let _ = BncsMessageComposer().build(messageIdentifier: .Null).writeToChannel(channel)
            print("[BNCS] Keep-alive.")

        case .Ping:
            let cookie = consumer.readUInt32()
            var composer = BncsMessageComposer()
            composer.write(cookie)
            let _ = composer.build(messageIdentifier: .Ping).writeToChannel(channel)
            print("[BNCS] Ping.")

        case .AuthInfo:
            print("[BNCS] Received auth challenge.")
            let loginType   = consumer.readUInt32()
            serverToken     = consumer.readUInt32()
            let udpValue    = consumer.readUInt32()
            let mpqFiletime = consumer.readUInt64()
            let mpqFilename = consumer.readNullTerminatedString()
            let challenge   = consumer.readNullTerminatedString()
            print("[BNCS] Auth challenge received. Login type \(loginType), MPQ \(mpqFilename) (\(mpqFiletime)), challenge: \(challenge).")

            let mpqFileNumber = Int(mpqFilename.cString(using: .ascii)![9] - 0x30)

            do {
                let checkRevisionResults = try CheckRevision.hash(mpqFileNumber: mpqFileNumber, challenge: challenge, files: [
                    "/Users/lafrance/dev/SwiftBncsLib/extern/hashfiles/D2DV/Game.exe"
                    ])

                var composer = BncsMessageComposer()
                composer.write(clientToken) // client token
                composer.write(checkRevisionResults.version)
                composer.write(checkRevisionResults.hash)
                composer.write(1 as UInt32) // keys
                composer.write(0 as UInt32) // spawn

                let hash = try! CdkeyDecodeAlpha26(cdkey: BotConfig.cdkey).hashForAuthCheck(clientToken: clientToken, serverToken: serverToken)
                composer.write(hash)

                composer.write(checkRevisionResults.info)
                composer.write("SwiftBot")
                print("[BNCS] Sending auth check...")
                let authCheckMessage = composer.build(messageIdentifier: BncsMessageIdentifier.AuthCheck)
                let _ = authCheckMessage.writeToChannel(channel)
            } catch (let error) {
                print("Error calculating CheckRevision(): \(error)")
            }

        case .AuthCheck:
            let authCheckResult = consumer.readUInt32()
            if authCheckResult == 0 {
                print("[BNCS] Auth check passed! Logging in..")

                state = .loggingIn

                let passwordHash = BotConfig.password.data(using: .ascii)!.doubleXsha1(clientToken: clientToken, serverToken: serverToken)
                var composer = BncsMessageComposer()
                composer.write(clientToken)
                composer.write(serverToken)
                composer.write(passwordHash)
                composer.write(BotConfig.username) // username
                let logonResponseMessage = composer.build(messageIdentifier: BncsMessageIdentifier.LogonResponse2)
                let _ = logonResponseMessage.writeToChannel(channel)

            } else {
                print("[BNCS] Auth check failed. \(authCheckResult)")
                state = .disconnecting
            }

        case .RequiredWork:
            let mpqFilename = consumer.readNullTerminatedString()
            print("[BNCS] Required work: \(mpqFilename)")

        case .LogonResponse2:
            let rawStatus = consumer.readUInt32()
            guard let status = BncsLogonResponse2Status(rawValue: rawStatus) else {
                print("[BNCS] Illegal logon response: \(rawStatus).")
                state = .disconnecting
                return
            }

            switch status {
            case .success:
                print("[BNCS] Login successful! Entering chat.")

                var enterChatComposer = BncsMessageComposer()
                enterChatComposer.write("")
                enterChatComposer.write("")
                let _ = enterChatComposer.build(messageIdentifier: .EnterChat).writeToChannel(channel)

                var joinChannelComposer = BncsMessageComposer()
                joinChannelComposer.write(1 as UInt32) // first join -- contrary to bnet docs, 1 is used by D2 as well
                joinChannelComposer.write("Diablo II") // channel name
                let _ = joinChannelComposer.build(messageIdentifier: .JoinChannel).writeToChannel(channel)

                var chatCommandComposer = BncsMessageComposer()
                chatCommandComposer.write("/join \(BotConfig.homeChannel)")
                let _ = chatCommandComposer.build(messageIdentifier: .ChatCommand).writeToChannel(channel)

            default:
                print("[BNCS] Logon failed: \(status).")
                state = .disconnecting
            }

        case .EnterChat:
            let uniqueUsername = consumer.readNullTerminatedString()
            let statstring = consumer.readNullTerminatedString()
            let accountName = consumer.readNullTerminatedString()
            print("[BNCS] Entered chat with unique username '\(uniqueUsername)', statstring '\(statstring)', account name '\(accountName)'.")

            state = .connected

        case .ChatEvent:
            let rawEventId = consumer.readUInt32()
            let flags = consumer.readUInt32()
            let ping = consumer.readUInt32()
            monitorDefunctValues(value: consumer.readUInt32(), expected: 0, description: "SID_CHATEVENT field 3, IP address")
            monitorDefunctValues(value: consumer.readUInt32(), expected: 0xBAADF00D, description: "SID_CHATEVENT field 4, account number")
            monitorDefunctValues(value: consumer.readUInt32(), expected: 0xBAADF00D, description: "SID_CHATEVENT field 5, registration authority")
            let username = consumer.readNullTerminatedString()
            let text = consumer.readNullTerminatedString()

            guard let eventId = BncsChatEventIdentifier(rawValue: rawEventId) else {
                print("[BNCS] Unrecognized chat event ID \(rawEventId). Username: \(username), text: \(text), flags: \(flags), ping: \(ping).")
                return
            }

            let chatEvent = BncsChatEvent(
                identifier: eventId,
                username: username,
                text: text,
                flags: flags,
                ping: ping
            )

            print("ChatEvent: \(chatEvent)")

        default:
            print("No parser for this packet!\n\(consumer)")
        }
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print("[BNCS] Error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.close(promise: nil)
    }
}

