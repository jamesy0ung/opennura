#if os(macOS)
import Foundation
import IOBluetooth

@MainActor
final class ClassicBTTransport: NSObject, NuraTransport {
    weak var delegate: NuraTransportDelegate?

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

    private var inquiry: IOBluetoothDeviceInquiry?
    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var frameBuffer = RFCOMMFrameBuffer()
    private var targetDevice: IOBluetoothDevice?

    private var pendingAck: UInt16 = 0
    private var pendingMinLen: Int = 0
    private var pendingCompletion: ((Result<[UInt8], Error>) -> Void)?
    private var timeoutTimer: Timer?
    private var connectTimer: Timer?

    private static let sppUUID = IOBluetoothSDPUUID(uuid16: 0x1101)

    func scan() {
        guard phase.isIdle else { return }
        phase = .scanning
        delegate?.transportDidLog("Classic BT: Looking for paired Nura devices...")

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            let nuraDevices = paired.filter { ($0.name ?? "").lowercased().contains("nura") }
            // Prefer the Classic BR/EDR entry. The LE entry ("... [LE]") has no
            // RFCOMM/SPP service record, so a Classic SDP query against it never
            // completes and the connection hangs.
            if let device = nuraDevices.first(where: { !($0.name ?? "").lowercased().contains("[le]") }) {
                delegate?.transportDidLog("Found paired device: \"\(device.name ?? "")\"")
                targetDevice = device
                performSDPQueryAndConnect(device)
                return
            }
            if let le = nuraDevices.first {
                delegate?.transportDidLog("Only an LE entry is paired: \"\(le.name ?? "")\"")
                phase = .failed("Only an LE entry is paired — pair the nuraphone as an audio device for Classic Bluetooth")
                return
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

    // MARK: - Connect

    private func performSDPQueryAndConnect(_ device: IOBluetoothDevice) {
        phase = .connecting
        startConnectTimeout()

        // macOS's CoreBluetooth-backed IOBluetooth must discover the RFCOMM channel
        // through a live SDP query before the channel can be opened — opening a
        // cached channel number directly fails with "No known channel cid N".
        // Use the *unfiltered* performSDPQuery; the uuids:-filtered variant never
        // delivers its completion callback. The channel is opened in
        // sdpQueryComplete, once the query has registered it with the coordinator.
        delegate?.transportDidLog("Performing SDP query...")
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess {
            delegate?.transportDidLog(String(format: "SDP query failed to start: 0x%08x", result))
            phase = .failed("SDP query failed")
        }
    }

    /// Resolves the GAIA RFCOMM channel from the device's cached SPP (0x1101)
    /// service record — the nuraphone's "CSR GAIA" service. Returns nil if no
    /// cached record exists yet. Note: we must not just take the first RFCOMM
    /// record, as that is the headset (HFP/HSP) profile, not GAIA.
    private func gaiaChannelID(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let record = device.getServiceRecord(for: Self.sppUUID) else { return nil }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, channelID != 0 else { return nil }
        return channelID
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
        connectTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .connecting else { return }
                self.delegate?.transportDidLog("Connection timed out (SDP/RFCOMM)")
                self.rfcommChannel?.close()
                self.rfcommChannel = nil
                self.targetDevice = nil
                self.phase = .failed("Connection timed out")
            }
        }
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
            } else {
                self.delegate?.transportDidLog(String(format: "SDP query returned 0x%08x; attempting open anyway", status))
            }
            self.openRFCOMMChannel(on: device)
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
