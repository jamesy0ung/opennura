#if os(macOS)
import CoreAudio
import Foundation
@preconcurrency import IOBluetooth

/// Classic Bluetooth (BR/EDR) RFCOMM/SPP transport for the nuraphone on macOS.
///
/// The nuraphone exposes its GAIA control channel over classic Bluetooth SPP
/// (the "CSR GAIA" service, UUID 0x1101), not Bluetooth LE, so on macOS this is
/// the transport that actually reaches the device while it's connected for
/// audio. Uses Apple's IOBluetooth framework.
@MainActor
final class ClassicBTTransport: NSObject, NuraTransport {
    weak var delegate: NuraTransportDelegate?
    var autoResetOnConnect = false

    private(set) var phase: ConnectionPhase = .idle {
        didSet {
            // Any move out of .connecting (handshaking, failed, idle) ends the
            // connect attempt, so the SDP/RFCOMM watchdog is no longer needed.
            if phase != .connecting {
                connectTimer?.invalidate()
                connectTimer = nil
            }
            delegate?.transportDidUpdatePhase(phase)
        }
    }

    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var intentionallyClosedChannels = Set<ObjectIdentifier>()
    private var frameBuffer = RFCOMMFrameBuffer()
    private var targetDevice: IOBluetoothDevice?

    private var pendingAck: UInt16 = 0
    private var pendingMinLen: Int = 0
    private var pendingCompletion: ((Result<[UInt8], Error>) -> Void)?
    private var pendingRawCompletion: ((Result<GaiaResponse, Error>) -> Void)?
    private var timeoutTimer: Timer?
    private var connectTimer: Timer?
    private var connectAttempt = 0
    private let maxConnectAttempts = 4

    private static let sppUUID = IOBluetoothSDPUUID(uuid16: 0x1101)

    private func audioDeviceName(_ device: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device, &nameAddress, 0, nil, &nameSize, &unmanagedName
        ) == noErr, let unmanagedName else { return nil }
        return (unmanagedName.takeRetainedValue() as String).lowercased()
    }

    private func audioDeviceUID(_ device: AudioDeviceID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device, &uidAddress, 0, nil, &uidSize, &unmanagedUID
        ) == noErr, let unmanagedUID else { return nil }
        return unmanagedUID.takeRetainedValue() as String
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr else { return [] }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    private func bluetoothAddress(fromAudioUID uid: String) -> String? {
        let pattern = #"(?i)([0-9a-f]{2}[:-]){5}[0-9a-f]{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: uid, range: NSRange(uid.startIndex..., in: uid)
              ),
              let range = Range(match.range, in: uid)
        else { return nil }
        return uid[range].replacingOccurrences(of: "-", with: ":")
    }

    private func classicDeviceForActiveAudioRoute(named deviceName: String) -> IOBluetoothDevice? {
        let baseName = deviceName.lowercased().replacingOccurrences(of: " [le]", with: "")
        for audioDevice in audioDeviceIDs() {
            guard let routeName = audioDeviceName(audioDevice),
                  (routeName == baseName
                      || routeName.contains(baseName)
                      || baseName.contains(routeName)),
                  let uid = audioDeviceUID(audioDevice),
                  let address = bluetoothAddress(fromAudioUID: uid)
            else { continue }
            return IOBluetoothDevice(addressString: address)
        }
        return nil
    }

    /// Names of Bluetooth devices currently published to Core Audio.
    ///
    /// On current macOS releases IOBluetoothDevice.isConnected() can remain
    /// false for headphones that are connected and carrying audio. Core Audio's
    /// device list is the reliable indication that an audio headset is present.
    private func connectedBluetoothAudioDeviceNames() -> Set<String> {
        var names = Set<String>()
        for device in audioDeviceIDs() {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport
            ) == noErr,
                transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                let name = audioDeviceName(device)
            else { continue }
            names.insert(name)
        }

        // Some macOS versions don't label the active headset with a Bluetooth
        // transport type. The default output route is nevertheless authoritative:
        // a paired device at another location cannot be the current output.
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDevice = AudioDeviceID(0)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &defaultSize,
            &defaultDevice
        ) == noErr, let name = audioDeviceName(defaultDevice), name.contains("nura") {
            names.insert(name)
        }
        return names
    }

    func scan() {
        guard phase.isIdle else { return }
        intentionallyClosedChannels.removeAll()
        // Defensive: release any channel left over from a prior connection, so
        // we don't try to reopen an already-registered RFCOMM channel id.
        if let stale = rfcommChannel {
            intentionallyClosedChannels.insert(ObjectIdentifier(stale))
            stale.close()
            rfcommChannel = nil
        }
        connectAttempt = 0
        phase = .scanning
        delegate?.transportDidLog("Classic BT: Looking for paired Nura devices...")

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            // On newer macOS versions pairedDevices() can expose only the LE
            // companion entry even while the Classic audio device is active.
            // recentDevices() still contains the Classic object needed for SDP.
            let recent = (IOBluetoothDevice.recentDevices(0) as? [IOBluetoothDevice]) ?? []
            var seenAddresses = Set<String>()
            let candidates = (recent + paired).filter {
                let key = $0.addressString ?? "\($0.name ?? "unnamed")|\(($0.name ?? "").contains("[LE]"))"
                return seenAddresses.insert(key).inserted
            }
            let nuraDevices = candidates.filter { ($0.name ?? "").lowercased().contains("nura") }
            let audioDeviceNames = connectedBluetoothAudioDeviceNames()
            let pairedSummary = nuraDevices.map {
                "\"\($0.name ?? "unnamed")\" (IOBluetooth connected: \($0.isConnected()))"
            }.joined(separator: ", ")
            delegate?.transportDidLog("Nura candidates: \(pairedSummary)")
            delegate?.transportDidLog(
                "Active Nura audio routes: \(audioDeviceNames.isEmpty ? "none" : audioDeviceNames.sorted().joined(separator: ", "))"
            )
            // A user may have several Nura products paired, including devices
            // that are nowhere nearby. Only target the entry matching the active
            // audio route. Do not reject a name ending in "[LE]": macOS retains
            // that suffix after historical LE pairing, and the same device may
            // still expose its Classic services when queried with IOBluetooth.
            let activeNuraRoutes = audioDeviceNames.filter { $0.contains("nura") }
            let connectedDevices = nuraDevices.filter { $0.isConnected() }

            if activeNuraRoutes.count > 1 {
                delegate?.transportDidLog(
                    "Multiple active Nura audio routes found: \(activeNuraRoutes.sorted().joined(separator: ", "))"
                )
                phase = .failed("Multiple Nura audio devices are active; leave only one connected")
                return
            }

            let device: IOBluetoothDevice?
            let hasActiveAudioRoute: Bool
            if let routeName = activeNuraRoutes.first {
                device = classicDeviceForActiveAudioRoute(named: routeName)
                hasActiveAudioRoute = true
                guard device != nil else {
                    delegate?.transportDidLog(
                        "Active Nura audio route found, but its Classic Bluetooth address could not be resolved"
                    )
                    phase = .failed("Could not resolve the active Nura device's Classic Bluetooth address")
                    return
                }
                delegate?.transportDidLog("Resolved Classic Bluetooth endpoint from active audio route")
            } else if connectedDevices.count == 1 {
                device = connectedDevices[0]
                hasActiveAudioRoute = false
            } else {
                device = nil
                hasActiveAudioRoute = false
            }

            if let device {
                delegate?.transportDidSelectDevice(named: device.name ?? "Nura device")
                delegate?.transportDidLog("Found connected device: \"\(device.name ?? "")\"")
                // Refuse to open the control channel while the headphones are
                // connected for audio. Observed behaviour (fw 606): the
                // nuraphone advertises GAIA on more than one RFCOMM channel, and
                // while audio holds the link macOS's SDP keeps surfacing a
                // channel that never finishes opening (e.g. 15), while the
                // channel that actually works (e.g. 1) only appears
                // intermittently on re-query. The result is an unreliable stall
                // loop. Connecting with audio disconnected reliably resolves the
                // working channel. Live control while audio plays is fine ONCE a
                // session is established; it's only the initial handshake that is
                // unreliable during audio, so we gate the connect, not the use.
                if device.isConnected() || hasActiveAudioRoute {
                    if autoResetOnConnect {
                        // Disconnect just this device's link (the equivalent of
                        // toggling it off in Bluetooth settings, but targeted so
                        // it doesn't touch the keyboard/mouse), then connect once
                        // it has settled into the paired-but-not-connected state
                        // where channel resolution is reliable.
                        delegate?.transportDidLog("\(device.name ?? "Nura device") is connected for audio; disconnecting that link first for a clean control connection...")
                        targetDevice = device
                        phase = .connecting
                        _ = device.closeConnection()
                        openCachedChannelWhenDisconnected(device)
                        return
                    }
                    delegate?.transportDidLog("Refusing to connect: \(device.name ?? "Nura device") is connected for audio. Turn on \"Disconnect audio automatically\", or disconnect it in macOS Bluetooth (keep it paired), then connect.")
                    phase = .failed("Disconnect the Nura device's audio first (keep it paired), then connect")
                    return
                }
                targetDevice = device
                phase = .connecting
                openCachedChannelWhenDisconnected(device)
                return
            }
            if !nuraDevices.isEmpty {
                let reason = connectedDevices.count > 1
                    ? "Multiple connected Nura devices found, but no active Nura audio route identifies which one to use"
                    : "Paired Nura devices found, but none is currently connected"
                delegate?.transportDidLog(reason)
                phase = .failed(
                    connectedDevices.count > 1
                        ? "Multiple Nura devices are connected; select one as the audio output"
                        : "Connect the Nura device in macOS Bluetooth, then try again"
                )
                return
            }
        }

        delegate?.transportDidLog("No paired Nura device found")
        phase = .failed("Pair and connect a Nura device in macOS Bluetooth, then try again")
    }

    func stopScan() {}

    func disconnect() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        failPending(NuraError.notReady)
        if let channel = rfcommChannel {
            intentionallyClosedChannels.insert(ObjectIdentifier(channel))
            channel.close()
        }
        rfcommChannel = nil
        targetDevice = nil
        phase = .idle
    }

    func sendFrame(
        _ frame: GaiaFrame,
        expectedAck: UInt16,
        minResponseLen: Int,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard let channel = rfcommChannel else {
            completion(.failure(NuraError.notReady))
            return
        }
        guard pendingCompletion == nil, pendingRawCompletion == nil else {
            completion(.failure(NuraError.busy))
            return
        }

        pendingAck = expectedAck
        pendingMinLen = minResponseLen
        pendingCompletion = completion

        if !writeFrame(frame, on: channel) {
            let cb = pendingCompletion
            pendingCompletion = nil
            pendingAck = 0
            cb?(.failure(NuraError.malformed("RFCOMM write failed")))
            return
        }
        startTimeout()
    }

    func sendRawFrameCapturingResponse(
        commandId: UInt16,
        payload: [UInt8],
        completion: @escaping (Result<GaiaResponse, Error>) -> Void
    ) {
        guard let channel = rfcommChannel else {
            completion(.failure(NuraError.notReady))
            return
        }
        guard pendingCompletion == nil, pendingRawCompletion == nil else {
            completion(.failure(NuraError.busy))
            return
        }

        pendingRawCompletion = completion
        pendingAck = 0
        pendingMinLen = 0

        if !writeFrame(GaiaFrame(commandId: commandId, payload: payload), on: channel) {
            pendingRawCompletion = nil
            completion(.failure(NuraError.malformed("RFCOMM write failed")))
            return
        }
        startTimeout()
    }

    // MARK: - Internal

    private func writeFrame(_ frame: GaiaFrame, on channel: IOBluetoothRFCOMMChannel) -> Bool {
        var bytes = [UInt8](frame.rfcommData)
        let result = channel.writeAsync(&bytes, length: UInt16(bytes.count), refcon: nil)
        if result != kIOReturnSuccess {
            delegate?.transportDidLog(String(format: "RFCOMM write failed: 0x%08x", result))
            return false
        }
        return true
    }

    private func failPending(_ error: Error) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        pendingAck = 0
        if let cb = pendingCompletion {
            pendingCompletion = nil
            cb(.failure(error))
            return
        }
        if let cb = pendingRawCompletion {
            pendingRawCompletion = nil
            cb(.failure(error))
        }
    }

    // MARK: - Connect

    /// Waits for the audio/baseband link to finish closing, then immediately
    /// opens the positively identified cached GAIA channel. Direct probing shows
    /// that a fresh SDP query stalls after disconnection, while this sequence
    /// reliably opens RFCOMM channel 1.
    private func openCachedChannelWhenDisconnected(
        _ device: IOBluetoothDevice,
        checksRemaining: Int = 40
    ) {
        guard phase == .connecting, targetDevice != nil else { return }
        if device.isConnected() {
            guard checksRemaining > 0 else {
                phase = .failed("Nuraphone audio link did not disconnect")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.openCachedChannelWhenDisconnected(
                        device, checksRemaining: checksRemaining - 1
                    )
                }
            }
            return
        }

        delegate?.transportDidLog("Audio link disconnected; opening cached GAIA service...")
        startConnectTimeout()
        openRFCOMMChannel(on: device)
    }

    /// Resolves the GAIA RFCOMM channel from the device's SDP records.
    ///
    /// We must NOT just take the first RFCOMM record or the plain SPP lookup:
    /// when the nuraphone is connected for audio, macOS's cached SDP can hand
    /// back the headset (HFP/HSP) channel (often channel 1) instead of the GAIA
    /// control channel (a higher channel, e.g. 14). Opening the headset channel
    /// fails with "No known channel cid 1". So we enumerate every record and
    /// pick the GAIA one deliberately.
    private func gaiaChannelID(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        // Only ever return a channel we can positively identify as GAIA, never a
        // guess. The nuraphone advertises "CSR GAIA" (legitimately on RFCOMM
        // channel 1). Writing control frames to any other channel is unsafe, so
        // if we can't find the GAIA record we refuse rather than guess.
        for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            var channel: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channel) == kIOReturnSuccess, channel != 0 else { continue }
            if (record.getServiceName() ?? "").lowercased().contains("gaia") {
                delegate?.transportDidLog("GAIA service on channel \(channel)")
                return channel
            }
        }
        // The SPP (0x1101) record is the GAIA service on the nuraphone.
        if let record = device.getServiceRecord(for: Self.sppUUID) {
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess, channel != 0 {
                delegate?.transportDidLog("Using SPP/GAIA channel \(channel)")
                return channel
            }
        }
        delegate?.transportDidLog("No GAIA service record found — not opening any channel")
        return nil
    }

    private func openRFCOMMChannel(on device: IOBluetoothDevice) {
        guard let channelID = gaiaChannelID(for: device) else {
            delegate?.transportDidLog("No GAIA (CSR GAIA / SPP) service record on device")
            phase = .failed("GAIA service not found")
            return
        }
        delegate?.transportDidLog("Opening RFCOMM channel \(channelID) to \(device.name ?? "device")...")

        var channel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(
            &channel,
            withChannelID: channelID,
            delegate: self
        )

        if result != kIOReturnSuccess {
            delegate?.transportDidLog(String(format: "Failed to open RFCOMM channel: 0x%08x", result))
            phase = .failed("RFCOMM open failed")
            return
        }

        rfcommChannel = channel
        delegate?.transportDidLog("RFCOMM channel opening (async)...")
    }

    private func startConnectTimeout() {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            // The timer fires on the main run loop, so we're already on the main
            // actor. assumeIsolated runs synchronously in that isolation, which
            // avoids the concurrent Task that tripped the captured-self warning.
            MainActor.assumeIsolated {
                guard let self, self.phase == .connecting else { return }

                // macOS's RFCOMM coordinator can leave channel id 1 half-open
                // after a prior connection, so the first open attempt stalls.
                // Tear down and retry with a fresh device handle a few times.
                if let channel = self.rfcommChannel {
                    self.intentionallyClosedChannels.insert(ObjectIdentifier(channel))
                    channel.close()
                }
                self.rfcommChannel = nil

                // Keep retrying the device selected at scan time. With automatic
                // audio disconnection enabled it is intentionally no longer
                // reported as connected, so re-selecting from the paired-device
                // list could switch to a different Nura product.
                if self.connectAttempt < self.maxConnectAttempts, let device = self.targetDevice {
                    self.connectAttempt += 1
                    self.delegate?.transportDidLog("Channel open stalled, retrying (\(self.connectAttempt)/\(self.maxConnectAttempts))...")
                    if device.isConnected() {
                        self.delegate?.transportDidLog("Audio reconnected; disconnecting it before retry...")
                        _ = device.closeConnection()
                    }
                    self.openCachedChannelWhenDisconnected(device)
                } else {
                    let audioHeld = self.targetDevice?.isConnected() ?? false
                    self.delegate?.transportDidLog("Connection timed out (SDP/RFCOMM)")
                    self.targetDevice = nil
                    self.phase = .failed(audioHeld
                        ? "Timed out - disconnect the nuraphone's audio in macOS Bluetooth, then retry"
                        : "Connection timed out - try again")
                }
            }
        }
    }

    private func startTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.pendingCompletion != nil || self.pendingRawCompletion != nil else { return }
                self.delegate?.transportDidLog("Command timed out")
                self.failPending(NuraError.timeout)
            }
        }
    }

    private func processReceivedData() {
        while let frameBytes = frameBuffer.tryReadFrame() {
            do {
                let response = try GaiaResponse.fromRFCOMM(frameBytes)
                guard response.vendorId == gaiaVendor else {
                    delegate?.transportDidLog(String(format: "  Ignoring non-Nura vendor: 0x%04x", response.vendorId))
                    continue
                }

                if response.isAck, response.commandId == (cmdEventNotification & 0x1FFF) {
                    delegate?.transportDidReceiveIndication(response)
                    continue
                }

                delegate?.transportDidLog(
                    String(
                        format: "<- GAIA cmd=0x%04x (%d bytes) payload=%@",
                        response.rawCommandId, response.payload.count, hexStr(Data(response.payload))
                    )
                )

                // Provisioning relay: hand back the next non-indication frame as-is.
                if pendingRawCompletion != nil {
                    timeoutTimer?.invalidate()
                    timeoutTimer = nil
                    let cb = pendingRawCompletion
                    pendingRawCompletion = nil
                    pendingAck = 0
                    cb?(.success(response))
                    continue
                }

                if response.isAck, response.commandId == (pendingAck & 0x1FFF) {
                    if response.payload.count < pendingMinLen {
                        delegate?.transportDidLog(
                            String(
                                format: "  (ignoring: only %d byte(s), need >=%d)",
                                response.payload.count, pendingMinLen
                            )
                        )
                        continue
                    }
                    timeoutTimer?.invalidate()
                    timeoutTimer = nil
                    let cb = pendingCompletion
                    pendingCompletion = nil
                    pendingAck = 0
                    cb?(.success(response.payload))
                }
            } catch {
                delegate?.transportDidLog("Malformed RFCOMM frame: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension ClassicBTTransport: IOBluetoothRFCOMMChannelDelegate {

    nonisolated func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel,
        status error: IOReturn
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.rfcommChannel === rfcommChannel else {
                self.delegate?.transportDidLog("Ignoring stale RFCOMM open callback")
                if error == kIOReturnSuccess {
                    self.intentionallyClosedChannels.insert(ObjectIdentifier(rfcommChannel))
                    rfcommChannel.close()
                }
                return
            }
            if error == kIOReturnSuccess {
                self.delegate?.transportDidLog("RFCOMM channel opened successfully")
                self.phase = .handshaking
            } else {
                self.delegate?.transportDidLog(String(format: "RFCOMM open failed: 0x%08x", error))
                self.rfcommChannel = nil
                self.phase = .failed("RFCOMM open failed")
            }
        }
    }

    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel,
        data dataPointer: UnsafeMutableRawPointer,
        length dataLength: Int
    ) {
        let dataCopy = Data(bytes: dataPointer, count: dataLength)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameBuffer.append(dataCopy)
            self.processReceivedData()
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let identifier = ObjectIdentifier(rfcommChannel)
            if self.intentionallyClosedChannels.remove(identifier) != nil {
                self.delegate?.transportDidLog("RFCOMM channel closed intentionally")
                return
            }
            guard self.rfcommChannel === rfcommChannel else {
                self.delegate?.transportDidLog("Ignoring stale RFCOMM close callback")
                return
            }
            self.delegate?.transportDidLog("RFCOMM channel closed")
            self.rfcommChannel = nil
            self.targetDevice = nil
            self.failPending(NuraError.notReady)
            self.phase = .failed("Disconnected")
        }
    }

    nonisolated func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel,
        refcon: UnsafeMutableRawPointer?,
        status error: IOReturn
    ) {
        guard error != kIOReturnSuccess else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.transportDidLog(String(format: "RFCOMM write error: 0x%08x", error))
        }
    }
}
#endif
