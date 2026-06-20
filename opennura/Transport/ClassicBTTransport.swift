#if os(macOS)
import Foundation
import IOBluetooth

@MainActor
final class ClassicBTTransport: NSObject, NuraTransport {
    weak var delegate: NuraTransportDelegate?

    private(set) var phase: ConnectionPhase = .idle {
        didSet { delegate?.transportDidUpdatePhase(phase) }
    }

    private var inquiry: IOBluetoothDeviceInquiry?
    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var frameBuffer = RFCOMMFrameBuffer()
    private var targetDevice: IOBluetoothDevice?

    private var pendingAck: UInt16 = 0
    private var pendingMinLen: Int = 0
    private var pendingCompletion: ((Result<[UInt8], Error>) -> Void)?
    private var timeoutTimer: Timer?

    private static let sppUUID = IOBluetoothSDPUUID(uuid16: 0x1101)

    func scan() {
        guard phase.isIdle else { return }
        phase = .scanning
        delegate?.transportDidLog("Classic BT: Looking for paired Nura devices...")

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired {
                let name = device.name ?? ""
                if name.lowercased().contains("nura") {
                    delegate?.transportDidLog("Found paired device: \"\(name)\"")
                    targetDevice = device
                    performSDPQueryAndConnect(device)
                    return
                }
            }
        }

        delegate?.transportDidLog("No paired Nura device found, starting inquiry...")
        guard let inq = IOBluetoothDeviceInquiry(delegate: self) else {
            delegate?.transportDidLog("Failed to create device inquiry")
            phase = .failed("Inquiry failed")
            return
        }
        inq.inquiryLength = 15
        inquiry = inq
        inq.start()
    }

    func stopScan() {
        inquiry?.stop()
        inquiry = nil
    }

    func disconnect() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        rfcommChannel?.close()
        rfcommChannel = nil
        targetDevice = nil
        inquiry?.stop()
        inquiry = nil
        let cb = pendingCompletion
        pendingCompletion = nil
        pendingAck = 0
        if cb != nil { cb?(.failure(NuraError.notReady)) }
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

        pendingAck = expectedAck
        pendingMinLen = minResponseLen
        pendingCompletion = completion

        var bytes = [UInt8](frame.rfcommData)
        let result = channel.writeAsync(&bytes, length: UInt16(bytes.count), refcon: nil)
        if result != kIOReturnSuccess {
            delegate?.transportDidLog(String(format: "RFCOMM write failed: 0x%08x", result))
            let cb = pendingCompletion
            pendingCompletion = nil
            pendingAck = 0
            cb?(.failure(NuraError.malformed("RFCOMM write failed")))
            return
        }

        startTimeout()
    }

    // MARK: - SDP Query + Connect

    private func performSDPQueryAndConnect(_ device: IOBluetoothDevice) {
        phase = .connecting
        delegate?.transportDidLog("Performing SDP query...")

        let result = device.performSDPQuery(self, uuids: [Self.sppUUID])
        if result != kIOReturnSuccess {
            delegate?.transportDidLog(String(format: "SDP query failed: 0x%08x — trying direct connect", result))
            openRFCOMMChannel(on: device)
        }
    }

    private func openRFCOMMChannel(on device: IOBluetoothDevice) {
        delegate?.transportDidLog("Opening RFCOMM channel to \(device.name ?? "device")...")

        var channelID: BluetoothRFCOMMChannelID = 0
        var foundChannel = false

        if let services = device.services as? [IOBluetoothSDPServiceRecord] {
            delegate?.transportDidLog("  Found \(services.count) SDP service(s)")
            for record in services {
                if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                    delegate?.transportDidLog("  RFCOMM channel ID: \(channelID)")
                    foundChannel = true
                    break
                }
            }
        }

        if !foundChannel {
            delegate?.transportDidLog("  No RFCOMM service found, trying channel 1")
            channelID = 1
        }

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

    private func startTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingCompletion != nil else { return }
                self.delegate?.transportDidLog("Command timed out")
                let cb = self.pendingCompletion
                self.pendingCompletion = nil
                self.pendingAck = 0
                cb?(.failure(NuraError.timeout))
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

                if response.rawCommandId == cmdEventNotification {
                    delegate?.transportDidReceiveIndication(response)
                    continue
                }

                delegate?.transportDidLog(
                    String(
                        format: "<- GAIA cmd=0x%04x (%d bytes) payload=%@",
                        response.rawCommandId, response.payload.count, hexStr(Data(response.payload))
                    )
                )

                if response.rawCommandId == pendingAck {
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

// MARK: - IOBluetoothDeviceAsyncCallbacks (SDP query completion)

extension ClassicBTTransport: IOBluetoothDeviceAsyncCallbacks {
    nonisolated func remoteNameRequestComplete(_ device: IOBluetoothDevice, status: IOReturn) {}

    nonisolated func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {}

    nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if status == kIOReturnSuccess {
                self.delegate?.transportDidLog("SDP query complete")
                self.openRFCOMMChannel(on: device)
            } else {
                self.delegate?.transportDidLog(String(format: "SDP query failed: 0x%08x — trying direct connect", status))
                self.openRFCOMMChannel(on: device)
            }
        }
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate

extension ClassicBTTransport: IOBluetoothDeviceInquiryDelegate {

    nonisolated func deviceInquiryDeviceFound(
        _ sender: IOBluetoothDeviceInquiry,
        device: IOBluetoothDevice
    ) {
        let name = device.name ?? ""
        guard name.lowercased().contains("nura") else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sender.stop()
            self.inquiry = nil
            self.targetDevice = device
            self.delegate?.transportDidLog("Inquiry found: \"\(name)\"")
            self.performSDPQueryAndConnect(device)
        }
    }

    nonisolated func deviceInquiryComplete(
        _ sender: IOBluetoothDeviceInquiry,
        error: IOReturn,
        aborted: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inquiry = nil
            if !aborted, case .scanning = self.phase {
                self.delegate?.transportDidLog("Inquiry complete, no Nura device found")
                self.phase = .failed("No device found")
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
            self.delegate?.transportDidLog("RFCOMM channel closed")
            self.rfcommChannel = nil
            self.targetDevice = nil
            let cb = self.pendingCompletion
            self.pendingCompletion = nil
            self.pendingAck = 0
            cb?(.failure(NuraError.notReady))
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
