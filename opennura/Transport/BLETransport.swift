import CoreBluetooth
import Foundation

@MainActor
final class BLETransport: NSObject, NuraTransport {
    weak var delegate: NuraTransportDelegate?
    var autoResetOnConnect = false   // not used on BLE; classic transport only

    private(set) var phase: ConnectionPhase = .idle {
        didSet { delegate?.transportDidUpdatePhase(phase) }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var rspChar: CBCharacteristic?
    private var pendingServiceCount = 0

    private var pendingAck: UInt16 = 0
    private var pendingMinLen: Int = 0
    private var pendingCompletion: ((Result<[UInt8], Error>) -> Void)?
    private var pendingRawCompletion: ((Result<GaiaResponse, Error>) -> Void)?
    private var pendingFrame: Data?
    private var writeRetries = 0
    private let maxRetries = 10
    private var pollTimer: Timer?
    private var pollAttempts = 0
    private let maxPollAttempts = 80
    private var seenDeviceNames: Set<String> = []

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func scan() {
        guard phase.isIdle else { return }
        peripheral = nil
        cmdChar = nil
        rspChar = nil
        seenDeviceNames.removeAll()
        phase = .scanning

        // A nuraphone that is already connected to the Mac (e.g. for audio)
        // often doesn't advertise over BLE, so a scan never finds it. Ask the
        // system for already-connected peripherals exposing the GAIA service
        // first, and only fall back to scanning.
        // CoreBluetooth does not always associate an existing NuraLoop link
        // with its vendor-specific GAIA service. It does expose the same
        // peripheral through standard services, so also retrieve by Device
        // Information and Battery, then require a Nura product name for those
        // fallback results.
        let gaiaConnected = central.retrieveConnectedPeripherals(withServices: [gaiaServiceUUID])
        let standardServiceUUIDs = [CBUUID(string: "180A"), CBUUID(string: "180F")]
        let namedConnected = standardServiceUUIDs
            .flatMap { central.retrieveConnectedPeripherals(withServices: [$0]) }
            .filter { BLETransport.nameMatchesNuraProduct($0.name ?? "") }
        var seenIdentifiers = Set<UUID>()
        let connected = (gaiaConnected + namedConnected).filter {
            seenIdentifiers.insert($0.identifier).inserted
        }
        if let p = connected.first {
            delegate?.transportDidSelectDevice(named: p.name ?? "Nura device")
            delegate?.transportDidLog("BLE: Using already-connected \"\(p.name ?? "<no name>")\"")
            phase = .connecting
            peripheral = p
            p.delegate = self
            central.connect(
                p,
                options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                ]
            )
            return
        }

        beginScanning()
    }

    private func beginScanning() {
        delegate?.transportDidLog("BLE: Scanning for Nura device...")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
    }

    /// True for a genuine Nura product name, or a Denon Perl / Perl Pro
    /// (a rebadged NuraTrue / NuraTrue Pro running the same GAIA firmware
    /// under a different advertised name - see docs/DENON-NURATRUE-PRO.md).
    /// Shared by both the already-connected-peripheral lookup in scan() and
    /// the live-advertisement matcher in didDiscover, so the two paths can't
    /// drift out of sync again.
    nonisolated static func nameMatchesNuraProduct(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("nura") || n.contains("denon") || n.contains("perl")
    }

    func disconnect() {
        stopPolling()
        let cb = pendingCompletion
        let rawCb = pendingRawCompletion
        pendingCompletion = nil
        pendingRawCompletion = nil
        pendingAck = 0
        cb?(.failure(NuraError.notReady))
        rawCb?(.failure(NuraError.notReady))
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        cmdChar = nil
        rspChar = nil
        phase = .idle
    }

    func sendFrame(
        _ frame: GaiaFrame,
        expectedAck: UInt16,
        minResponseLen: Int,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard cmdChar != nil, rspChar != nil else {
            completion(.failure(NuraError.notReady))
            return
        }
        pendingAck = expectedAck
        pendingMinLen = minResponseLen
        pendingCompletion = completion
        writeRetries = 0
        pendingFrame = frame.bleData
        writeFrame()
    }

    func sendRawFrameCapturingResponse(
        commandId: UInt16,
        payload: [UInt8],
        completion: @escaping (Result<GaiaResponse, Error>) -> Void
    ) {
        guard cmdChar != nil, rspChar != nil else {
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
        writeRetries = 0
        pendingFrame = GaiaFrame(commandId: commandId, payload: payload).bleData
        writeFrame()
    }

    // MARK: - Internal

    private var hasPending: Bool {
        pendingCompletion != nil || pendingRawCompletion != nil
    }

    private func failPending(_ error: Error) {
        stopPolling()
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

    private func writeFrame() {
        guard let ch = cmdChar, let p = peripheral, let frame = pendingFrame
        else { return }
        let wType: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(frame, for: ch, type: wType)
        startPolling()
    }

    private func startPolling() {
        pollAttempts = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollTick() {
        guard hasPending else {
            stopPolling()
            return
        }
        pollAttempts += 1
        if pollAttempts >= maxPollAttempts {
            failPending(NuraError.timeout)
        }
    }

    private func resolveResponse(_ payload: [UInt8]) {
        stopPolling()
        let cb = pendingCompletion
        pendingCompletion = nil
        pendingAck = 0
        cb?(.success(payload))
    }

    private func resolveRawResponse(_ response: GaiaResponse) {
        stopPolling()
        let cb = pendingRawCompletion
        pendingRawCompletion = nil
        pendingAck = 0
        cb?(.success(response))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                let auth = CBCentralManager.authorization
                if auth != .allowedAlways {
                    delegate?.transportDidLog("Bluetooth authorization: \(auth.rawValue) — may need to grant in System Settings > Privacy > Bluetooth")
                }
                delegate?.transportDidLog("Bluetooth on")
                if case .scanning = phase {
                    central.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                }
            case .poweredOff:
                delegate?.transportDidLog("Bluetooth OFF")
                phase = .failed("Bluetooth off")
            case .unauthorized:
                delegate?.transportDidLog("Bluetooth unauthorized — grant access in System Settings > Privacy > Bluetooth")
                phase = .failed("Bluetooth unauthorized")
            default:
                delegate?.transportDidLog("Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name =
            peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "<no name>"
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // Match the Nura product family (Nuraphone, NuraLoop, etc.) or a
        // Denon-badged Perl / Perl Pro. The device-info exchange remains the
        // safety gate before authentication.
        var match = BLETransport.nameMatchesNuraProduct(name)
        if !match {
            // Any device advertising the Qualcomm GAIA service is a candidate,
            // regardless of the name it broadcasts.
            match = advertisedServices.contains(gaiaServiceUUID)
        }
        if !match,
            let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        {
            let suffix = [UInt8](mfg).suffix(6)
            match = suffix == ArraySlice(nuraphoneBdAddrSuffix) || suffix == ArraySlice(denonPerlProBdAddrSuffix)
        }

        MainActor.assumeIsolated {
            // Diagnostic: log every distinct device seen while scanning, so an
            // unrecognised nuraphone name shows up in the log.
            if self.seenDeviceNames.insert(name).inserted {
                let svc = advertisedServices.isEmpty
                    ? ""
                    : " services=[\(advertisedServices.map { $0.uuidString }.joined(separator: ", "))]"
                delegate?.transportDidLog("  saw device: \"\(name)\"\(svc)")
            }
        }

        guard match else { return }

        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            central.stopScan()
            delegate?.transportDidSelectDevice(named: name)
            delegate?.transportDidLog("Found \"\(name)\" - connecting")
            phase = .connecting
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(
                peripheral,
                options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                ]
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            delegate?.transportDidLog("Connected - discovering services")
            phase = .discovering
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            delegate?.transportDidLog("Failed to connect: \(error?.localizedDescription ?? "unknown")")
            phase = .failed("Connect failed")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // Resolve any in-flight request so awaiting callers (e.g. the
            // provisioning relay) don't hang when the device drops. Safe/no-op
            // after a manual disconnect(), which already cleared the callbacks.
            failPending(NuraError.notReady)
            cmdChar = nil
            rspChar = nil
            self.peripheral = nil
            if let e = error {
                delegate?.transportDidLog("Disconnected (error): \(e.localizedDescription)")
                phase = .failed("Disconnected")
            } else {
                delegate?.transportDidLog("Disconnected cleanly")
                phase = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        MainActor.assumeIsolated {
            if let e = error {
                delegate?.transportDidLog("Service discovery error: \(e.localizedDescription)")
                return
            }
            let services = peripheral.services ?? []
            delegate?.transportDidLog("Found \(services.count) service(s)")
            pendingServiceCount = services.count
            for svc in services {
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            pendingServiceCount -= 1
            if let e = error {
                delegate?.transportDidLog("Char discovery error (\(service.uuid)): \(e.localizedDescription)")
            } else {
                for ch in service.characteristics ?? [] {
                    if ch.uuid == gaiaCommandUUID {
                        cmdChar = ch
                        delegate?.transportDidLog("  GAIA CMD char found")
                    }
                    if ch.uuid == gaiaResponseUUID {
                        rspChar = ch
                        delegate?.transportDidLog("  GAIA RSP char found")
                    }
                    if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: ch)
                    } else if ch.uuid == gaiaResponseUUID {
                        peripheral.setNotifyValue(true, for: ch)
                    }
                }
            }
            if pendingServiceCount <= 0 {
                if cmdChar != nil, rspChar != nil {
                    phase = .handshaking
                } else {
                    delegate?.transportDidLog("GAIA characteristics not found")
                    phase = .failed("GAIA chars not found")
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let e = error {
                delegate?.transportDidLog("Notify error (\(characteristic.uuid)): \(e.localizedDescription)")
            } else {
                delegate?.transportDidLog("Subscribed to \(characteristic.uuid) isNotifying=\(characteristic.isNotifying)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let capturedValue = characteristic.value
        let capturedError = error

        MainActor.assumeIsolated {
            if let e = capturedError {
                if uuid == gaiaResponseUUID, hasPending { return }
                delegate?.transportDidLog("Value error (\(uuid)): \(e.localizedDescription)")
                return
            }
            guard uuid == gaiaResponseUUID,
                let data = capturedValue,
                let response = GaiaResponse.fromBLE(data)
            else { return }
            guard response.vendorId == gaiaVendor else { return }

            if response.isAck, response.commandId == (cmdEventNotification & 0x1FFF) {
                delegate?.transportDidReceiveIndication(response)
                return
            }

            delegate?.transportDidLog(
                String(
                    format: "<- GAIA cmd=0x%04x (%d bytes) payload=%@",
                    response.rawCommandId, response.payload.count, hexStr(Data(response.payload))
                )
            )

            // Provisioning relay: accept the next non-indication frame as-is.
            if pendingRawCompletion != nil {
                resolveRawResponse(response)
                return
            }

            if response.isAck, response.commandId == (pendingAck & 0x1FFF) {
                if response.payload.count < pendingMinLen {
                    delegate?.transportDidLog(
                        String(
                            format: "  (ignoring: only %d byte(s), need >=%d)",
                            response.payload.count, pendingMinLen
                        )
                    )
                    return
                }
                resolveResponse(response.payload)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let capturedError = error
        MainActor.assumeIsolated {
            guard uuid == gaiaCommandUUID else { return }
            if let e = capturedError {
                delegate?.transportDidLog("Write error: \(e.localizedDescription)")
                let ns = e as NSError
                let isEnc =
                    ns.domain == CBATTErrorDomain
                    && (ns.code == CBATTError.insufficientEncryption.rawValue
                        || ns.code == CBATTError.insufficientAuthentication.rawValue
                        || ns.code == CBATTError.insufficientResources.rawValue)
                if isEnc, writeRetries < maxRetries {
                    writeRetries += 1
                    let delay = min(Double(writeRetries), 3.0)
                    delegate?.transportDidLog("  Encryption not ready, retry \(writeRetries)/\(maxRetries) in \(Int(delay))s")
                    stopPolling()
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if let rsp = self.rspChar, let p = self.peripheral {
                            p.setNotifyValue(true, for: rsp)
                        }
                        self.writeFrame()
                    }
                } else {
                    failPending(e)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        MainActor.assumeIsolated {
            delegate?.transportDidLog("Services changed - re-discovering")
            peripheral.discoverServices(nil)
        }
    }
}
