import Combine
import Foundation

#if os(macOS)
enum MacBluetoothTransport: String, CaseIterable, Identifiable {
    case rfcomm = "RFCOMM"
    case btle = "BTLE"
    
    var id: Self { self }
}
#endif

@MainActor
final class NuraDeviceManager: NSObject, ObservableObject {
    
    @Published var phase: ConnectionPhase = .idle
    @Published var logs: [String] = []
    @Published private(set) var connectedDeviceName = "Nura device"
    /// Becomes non-nil only after a recovered key has been saved successfully.
    /// This is the UI's completion event for the provisioning flow.
    @Published private(set) var recoveredDeviceSerial: String?
    
    /// When on, connecting first disconnects the headphones' audio link (macOS
    /// only), so the control handshake is reliable without visiting Bluetooth
    /// settings. Persisted; on by default.
    @Published var autoDisconnectAudio: Bool = UserDefaults.standard.object(forKey: "autoDisconnectAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoDisconnectAudio, forKey: "autoDisconnectAudio") }
    }
    
#if os(macOS)
    /// Transport used for the next connection. Original Nuraphones generally
    /// use RFCOMM; products such as NuraLoop expose the GAIA channel over BLE.
    @Published var macBluetoothTransport: MacBluetoothTransport {
        didSet {
            UserDefaults.standard.set(macBluetoothTransport.rawValue, forKey: "macBluetoothTransport")
            replaceTransportForMac()
        }
    }
#endif
    
    let state = NuraDeviceState()
    let provisioning = NuraProvisioningManager()
    
    /// App-side custom profile names (display only; not sent to the device).
    @Published var localProfileNames: [Int: String] = [:]
    
    enum Mode { case control, provision }
    private var mode: Mode = .control
    
    private var transport: NuraTransport
    private var nuraKey: [UInt8] = []
    private var session: NuraSession?
    private var gaiaCommandBusy = false
    private let configStore = NuraConfigStore()
    private var batteryTimer: Timer?
    
    /// True when at least one device key is stored (used to offer auto-connect).
    var hasSavedDevices: Bool { !configStore.load().devices.isEmpty }
    
    /// Connects automatically if a device key is already saved and we're idle.
    func autoConnectIfAvailable() {
        guard phase.isIdle, hasSavedDevices else { return }
        connect()
    }
    
    override init() {
        // The nuraphone exposes GAIA over classic Bluetooth SPP, which on macOS
        // is reached via IOBluetooth RFCOMM. iOS can't do RFCOMM to non-MFi
        // devices, so it falls back to BLE.
#if os(macOS)
        let savedTransport = UserDefaults.standard.string(forKey: "macBluetoothTransport")
            .flatMap(MacBluetoothTransport.init(rawValue:)) ?? .rfcomm
        self.macBluetoothTransport = savedTransport
        self.transport = savedTransport == .btle ? BLETransport() : ClassicBTTransport()
#else
        self.transport = BLETransport()
#endif
        super.init()
        self.transport.delegate = self
    }
    
#if os(macOS)
    private func replaceTransportForMac() {
        // The picker is disabled during an active connection. Still guard here
        // so a programmatic change cannot replace a live transport.
        guard phase.isIdle else { return }
        transport.stopScan()
        transport.delegate = nil
        transport.disconnect()
        transport = macBluetoothTransport == .btle
        ? BLETransport()
        : ClassicBTTransport()
        transport.delegate = self
        addLog("Bluetooth transport: \(macBluetoothTransport.rawValue)")
    }
#endif
    
    // MARK: - Provisioning (recover device key from the Nura backend)
    
    /// Connects to the headphones and runs backend-assisted provisioning to
    /// recover and store the long-lived device key. Requires being signed in.
    func fetchDeviceKey() {
        guard phase.isIdle else { return }
        guard provisioning.isLoggedIn else {
            addLog("Provisioning: sign in to your Nura account first")
            provisioning.status = "Sign in to your Nura account first."
            return
        }
        mode = .provision
        recoveredDeviceSerial = nil
        session = nil
        gaiaCommandBusy = false
        nuraKey = []
        state.reset()
        connectedDeviceName = "Nura device"
        phase = .scanning
        addLog("Provisioning: scanning for a Nura device (make sure it's on and worn)...")
        transport.autoResetOnConnect = autoDisconnectAudio
        transport.scan()
    }
    
    /// Clears the transient completion event after the provisioning UI closes.
    /// The saved device key itself is unaffected.
    func clearRecoveredDeviceResult() {
        recoveredDeviceSerial = nil
    }
    
    private func runProvisioningRelay(serial: Int, firmware: Int) {
        phase = .handshaking
        addLog("Provisioning: recovering device key from Nura backend...")
        let maxPacket = configStore.load().deviceBySerial(String(serial))?.maxPacketLengthHint ?? 182
        
        let sender: NuraProvisioningManager.FrameSender = { [weak self] cmd, payload in
            try await withCheckedThrowingContinuation { continuation in
                guard let self else {
                    continuation.resume(throwing: NuraError.notReady)
                    return
                }
                self.transport.sendRawFrameCapturingResponse(commandId: cmd, payload: payload) { result in
                    switch result {
                    case .success(let response):
                        continuation.resume(returning: NuraProvisioningManager.RelayResponse(
                            vendorId: response.vendorId,
                            rawCommandId: response.rawCommandId,
                            payload: response.payload
                        ))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        Task { @MainActor in
            do {
                let key = try await provisioning.recoverDeviceKey(
                    serial: serial,
                    firmwareVersion: firmware,
                    maxPacketLength: maxPacket,
                    sendFrame: sender
                )
                provisioning.saveDeviceKey(
                    key,
                    serial: serial,
                    firmwareVersion: firmware,
                    maxPacketLength: maxPacket,
                    friendlyName: connectedDeviceName,
                    deviceType: deviceTypeName(forSerial: serial)
                )
                recoveredDeviceSerial = String(serial)
                addLog("Provisioning: device key recovered and saved for serial \(serial)")
                mode = .control
                // Continue straight into a normal encrypted session so the
                // device is immediately usable with the recovered key.
                if applyConfiguredKey(forSerial: serial) {
                    runHandshake()
                } else {
                    phase = .idle
                }
            } catch {
                addLog("Provisioning failed: \(error.localizedDescription)")
                phase = .failed("Provisioning failed")
                mode = .control
            }
        }
    }
    
    // MARK: - Connection
    
    func connect() {
        guard phase.isIdle else { return }
        mode = .control
        session = nil
        gaiaCommandBusy = false
        nuraKey = []
        state.reset()
        connectedDeviceName = "Nura device"
        phase = .scanning
        addLog("OpenNura \(AppInfo.displayVersion)")
        addLog("Scanning for a Nura device...")
        transport.autoResetOnConnect = autoDisconnectAudio
        transport.scan()
    }
    
    func disconnect() {
        stopBatteryTimer()
        transport.stopScan()
        transport.disconnect()
        mode = .control
        session = nil
        gaiaCommandBusy = false
        state.reset()
        connectedDeviceName = "Nura device"
        phase = .idle
        addLog("Disconnected")
    }
    
    /// Immediately tears the connection down and reports a failure. Used when
    /// something looks wrong enough that we should stop talking to the device
    /// rather than send it any more frames.
    private func abortForSafety(_ reason: String) {
        stopBatteryTimer()
        transport.stopScan()
        transport.disconnect()
        mode = .control
        session = nil
        gaiaCommandBusy = false
        state.reset()
        phase = .failed(reason)
        addLog("Aborted for safety: \(reason)")
    }
    
    // MARK: - Battery auto-refresh
    
    private func startBatteryTimer() {
        stopBatteryTimer()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBattery() }
        }
    }
    
    private func stopBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }
    
    // MARK: - ANC
    
    func setAncState(anc: Bool, social: Bool) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        // Optimistic: reflect the new mode immediately so the segmented control
        // doesn't flicker back to the old value while we wait for the reply.
        let previous = state.anc
        state.anc = NuraAncState(ancEnabled: anc, passthroughEnabled: social)
        addLog("-> SetAncState anc=\(anc ? "ON" : "OFF") social=\(social ? "ON" : "OFF")")
        sendEncrypted(opcode: cmdSetAncState, params: [profileId, anc ? 0x01 : 0x00, social ? 0x01 : 0x00]) { [weak self] result in
            switch result {
            case .success:
                self?.addLog("<- ANC \(anc ? "ON" : "OFF"), Social \(social ? "ON" : "OFF")")
            case .failure(let e):
                self?.state.anc = previous
                self?.addLog("<- SetAncState error: \(e.localizedDescription)")
            }
        }
    }
    
    func setAncEnabled(_ enabled: Bool) {
        setAncState(anc: enabled, social: state.passthroughEnabled)
    }
    
    /// Sets the combined noise mode (Off / ANC / Passthrough).
    func setAncMode(_ mode: NuraAncMode) {
        switch mode {
        case .off: setAncState(anc: false, social: false)
        case .anc: setAncState(anc: true, social: false)
        case .passthrough: setAncState(anc: false, social: true)
        }
    }
    
    func setSocialMode(_ enabled: Bool) {
        setAncState(anc: state.ancEnabled, social: enabled)
    }
    
    func setAncLevel(_ level: Int) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        addLog("-> SetAncLevel \(level)")
        let opcode = family == .nuraTruePro ? cmdProSetAncLevel : cmdSetAncLevel
        sendEncrypted(opcode: opcode, params: [profileId, UInt8(level)]) { [weak self] result in
            switch result {
            case .success:
                self?.state.ancLevel = level
                self?.addLog("<- ANC level set to \(level)")
            case .failure(let e):
                self?.addLog("<- SetAncLevel error: \(e.localizedDescription)")
            }
        }
        // Picking a level should be audible immediately even if noise
        // control was off.
        if family == .nuraTruePro {
            setGlobalAncEnabled(true)
        }
    }
    
    func setGlobalAncEnabled(_ enabled: Bool) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        let opcode = family == .nuraTruePro ? cmdProSetGlobalAncEnabled : cmdSetGlobalAncEnabled
        sendEncrypted(opcode: opcode, params: [profileId, enabled ? 0x01 : 0x00]) { [weak self] result in
            if case .success = result { self?.state.globalAncEnabled = enabled }
        }
    }
    
    // MARK: - Immersion
    
    func setImmersion(_ level: Int) {
        guard phase.isReady else {
            addLog("Not ready")
            return
        }
        let profileId = UInt8(state.profileId ?? 0)
        addLog("-> SetImmersion profile \(profileId) level \(level)")
        let opcode: UInt16
        let params: [UInt8]
        if family == .nuraTruePro {
            // Range is -3...+3, so the raw byte is offset by 3, plus a
            // trailing flag byte that was always 0x01 in the capture.
            opcode = cmdProSetImmersion
            params = [profileId, UInt8(level + 3), 0x01]
        } else {
            opcode = cmdSetKickitParams
            params = [profileId] + kickitParams(for: level)
        }
        sendEncrypted(opcode: opcode, params: params) { [weak self] result in
            switch result {
            case .success:
                self?.state.immersionLevel = level
                self?.addLog("<- Immersion set to \(level) (profile \(profileId))")
            case .failure(let e):
                self?.addLog("<- SetImmersion error: \(e.localizedDescription)")
            }
        }
    }
    
    // MARK: - Sound mode
    
    func setSoundMode(_ mode: NuraPersonalisationMode) {
        guard phase.isReady else { return }
        // Optimistic update to avoid the segmented control flickering back.
        let previous = state.personalisationMode
        state.personalisationMode = mode
        addLog("-> SetPersonalisedMode \(mode.rawValue)")
        let opcode = family == .nuraTruePro ? cmdProSetPersonalisedMode : cmdSetPersonalisedMode
        // Inverted from the legacy byte on this device (confirmed on-device).
        let byte: UInt8 = family == .nuraTruePro ? (mode == .personalised ? 0x00 : 0x01) : mode.byte
        sendEncrypted(opcode: opcode, params: [byte]) { [weak self] result in
            switch result {
            case .success:
                self?.addLog("<- Sound mode \(mode.rawValue)")
            case .failure(let e):
                self?.state.personalisationMode = previous
                self?.addLog("<- SetPersonalisedMode error: \(e.localizedDescription)")
            }
        }
    }
    
    // MARK: - Spatial
    
    func setSpatialEnabled(_ enabled: Bool) {
        guard phase.isReady else { return }
        let opcode: UInt16
        let params: [UInt8]
        if family == .nuraTruePro {
            opcode = cmdProSetSpatialState
            params = [UInt8(state.profileId ?? 0), enabled ? 0x01 : 0x00]
        } else {
            opcode = cmdSetSpatialState
            params = [enabled ? 0x01 : 0x00]
        }
        sendEncrypted(opcode: opcode, params: params) { [weak self] result in
            if case .success = result { self?.state.spatialEnabled = enabled }
        }
    }
    
    // MARK: - Profiles
    
    func selectProfile(_ profileId: Int) {
        guard phase.isReady else { return }
        addLog("-> SelectProfile \(profileId)")
        sendEncrypted(opcode: cmdSelectProfile, params: [UInt8(profileId)]) { [weak self] result in
            switch result {
            case .success:
                self?.state.profileId = profileId
                self?.addLog("<- Profile selected: \(profileId)")
                // Immersion and ANC are per-profile, so re-read them (pure reads)
                // for the new profile so the controls reflect this profile.
                self?.refreshProfileScopedState()
            case .failure(let e):
                self?.addLog("<- SelectProfile error: \(e.localizedDescription)")
            }
        }
    }
    
    /// Re-reads the per-profile values (immersion, ANC) for the current profile.
    /// These are pure reads and are already part of the safe startup set.
    private func refreshProfileScopedState() {
        readAncState { [weak self] in
            self?.readKickitParams {}
        }
    }
    
    // MARK: - Battery
    
    func refreshBattery() {
        guard phase.isReady else { return }
        sendEncrypted(opcode: cmdGetBatteryStatus, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let battery = NuraResponseParsers.decodeBatteryStatus(pt) {
                self?.state.battery = battery
                self?.addLog("<- Battery: \(battery.batteryPercentage)%")
            }
        }
    }
    
    // MARK: - Button configuration
    
    func setButtonConfiguration(_ config: NuraButtonConfiguration) {
        guard phase.isReady else { return }
        let caps = NuraButtonCapabilities.for(family)
        let bytes = config.toBytes(supportsDoubleTap: caps.supportsDoubleTap, supportsTripleTap: caps.supportsTripleTap)
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdSetButtonConfigV1, params: [profileId] + bytes) { [weak self] result in
            if case .success = result { self?.state.buttons = config }
        }
    }
    
    // MARK: - Discoverable mode
    
    /// Puts the headset into Bluetooth pairing mode for 120 seconds
    func enterDiscoverableMode(completion: @escaping (Result<Void, Error>) -> Void) {
        guard phase.isReady else { completion(.failure(NuraError.notReady)); return }
        addLog("-> EnterDiscoverable (120 s)")
        // Param is a big-endian uint16 timeout: pack(">H", 120) = [0x00, 0x78]
        sendEncrypted(opcode: cmdEnterDiscoverable, params: [0x00, 0x78]) { [weak self] result in
            switch result {
            case .success:
                self?.addLog("<- EnterDiscoverable: success")
                completion(.success(()))
            case .failure(let e):
                self?.addLog("<- EnterDiscoverable error: \(e.localizedDescription)")
                completion(.failure(e))
            }
        }
    }
    
    // MARK: - Dial configuration
    
    func setDialConfiguration(_ config: NuraDialConfiguration) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdSetDialConfig, params: [profileId] + config.toBytes()) { [weak self] result in
            if case .success = result { self?.state.dial = config }
        }
    }
    
    // MARK: - Logging
    
    func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(ts)] \(msg)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
    
    // MARK: - GAIA frame send
    
    private func sendGaiaFrame(
        cmd: UInt16,
        payload: [UInt8],
        expectedAck: UInt16,
        minResponseLen: Int = 0,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        let frame = GaiaFrame(commandId: cmd, payload: payload)
        transport.sendFrame(frame, expectedAck: expectedAck, minResponseLen: minResponseLen, completion: completion)
    }
    
    // MARK: - Encrypted command
    
    private func sendEncrypted(
        opcode: UInt16,
        params: [UInt8],
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(NuraError.notReady))
            return
        }
        guard !gaiaCommandBusy else {
            completion(.failure(NuraError.busy))
            return
        }
        gaiaCommandBusy = true
        
        var plain: [UInt8] = [UInt8((opcode >> 8) & 0xFF), UInt8(opcode & 0xFF)]
        plain += params
        let (tag, ct) = session.encryptAppToDev(plain)
        
        addLog(String(format: "  enc opcode=0x%04x ctr=%d", opcode, session.encCtr - 1))
        
        sendGaiaFrame(
            cmd: cmdEncryptedCommand,
            payload: tag + ct,
            expectedAck: cmdEncryptedResponse | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            self.gaiaCommandBusy = false
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                guard !payload.isEmpty else {
                    completion(.failure(NuraError.malformed("empty encrypted response")))
                    return
                }
                let status = Int(payload[0])
                guard status == 0 else {
                    completion(.failure(NuraError.status(String(format: "0x%04x", opcode), status)))
                    return
                }
                let body = Array(payload[1...])
                do {
                    let raw = try session.decryptDevToApp(body)
                    let pt = raw.count > 1 ? Array(raw[1...]) : []
                    self.addLog(String(format: "  dec opcode=0x%04x plain=%@", opcode, hexStr(Data(pt))))
                    completion(.success(pt))
                } catch {
                    completion(.failure(NuraError.crypto("tag mismatch decrypting response")))
                }
            }
        }
    }
    
    // MARK: - Connection & GAIA sequence
    
    private func runGaiaSequence() {
        addLog("GAIA: GetDeviceInfo (0x0001)")
        sendGaiaFrame(
            cmd: cmdGetDeviceInfo,
            payload: [],
            expectedAck: cmdGetDeviceInfo | gaiaAckBit
        ) { [weak self] result in
            guard let self else { return }
            // SAFETY GATE: the very first exchange must look like a real GAIA
            // device-info reply. If it doesn't (wrong channel, garbled state),
            // tear the connection down immediately and send nothing further,
            // rather than pushing more frames into an unknown channel.
            guard case .success(let p) = result,
                  let info = NuraResponseParsers.decodeDeviceInfo(p),
                  info.serialNumber > 0, info.firmwareVersion > 0 else {
                self.addLog("GetDeviceInfo failed or implausible - aborting for safety")
                self.abortForSafety("Unrecognised device response")
                return
            }
            self.addLog("  device info: \(hexStr(Data(p)))")
            self.state.deviceInfo = info
            self.persistConnectedDeviceIdentity(serial: info.serialNumber)
            self.addLog("  serial=\(info.serialNumber) fw=\(info.firmwareVersion)")
            if self.mode == .provision {
                self.runProvisioningRelay(serial: info.serialNumber, firmware: info.firmwareVersion)
                return
            }
            guard self.applyConfiguredKey(forSerial: info.serialNumber) else {
                self.abortForSafety("No usable key for this device - recover or re-enter it in Devices")
                return
            }
            self.runHandshake()
        }
    }
    
    private func applyConfiguredKey(forSerial serial: Int) -> Bool {
        let config = configStore.load()
        guard let entry = config.deviceBySerial(String(serial)) else {
            addLog("No saved device for serial \(serial). Recover its key from the Devices tab.")
            return false
        }
        guard let keyBytes = entry.getDeviceKeyBytes() else {
            // The device is known but its key isn't readable. This is almost
            // always a code-signature change (e.g. switching to a notarised or
            // hardened build): macOS binds Keychain items to the signing
            // identity, so a newly-signed build can't read what an earlier build
            // stored. The key isn't gone; just recover or paste it again here.
            addLog("Device \(serial) is known but its saved key can't be read (the app's signature changed, e.g. a new notarised build). Re-recover or re-enter the key in the Devices tab; it will then stick.")
            return false
        }
        nuraKey = keyBytes
        addLog("  using configured key for serial \(serial)")
        return true
    }
    
    private func deviceTypeName(forSerial serial: Int) -> String {
        NuraDeviceFamily.forSerial(serial).displayName
    }
    
    private func persistConnectedDeviceIdentity(serial: Int) {
        var config = configStore.load()
        let serialString = String(serial)
        guard var entry = config.deviceBySerial(serialString) else { return }
        entry.friendlyName = connectedDeviceName
        entry.type = deviceTypeName(forSerial: serial)
        config.upsertDevice(entry)
        configStore.save(config)
    }
    
    private func runHandshake() {
        phase = .handshaking
        addLog("GAIA: CryptoAppGenerateChallenge (0x0002)")
        sendGaiaFrame(
            cmd: cmdCryptoGenerateChallenge,
            payload: [],
            expectedAck: cmdCryptoGenerateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog("Handshake step 1 failed: \(e.localizedDescription)")
                self.abortForSafety("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoGenerateChallenge status=\(s)")
                    self.abortForSafety("Handshake status \(s)")
                    return
                }
                let challenge = Array(payload[1..<17])
                self.addLog("  challenge=\(hexStr(Data(challenge)))")
                self.continueHandshake(challenge: challenge)
            }
        }
    }
    
    private func continueHandshake(challenge: [UInt8]) {
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { nonce[i] = UInt8.random(in: 0...255) }
        addLog("  nonce=\(hexStr(Data(nonce)))")
        
        let j0App = makeJ0(nonce: nonce, counter: 1, deviceToApp: false)
        let (_, appGmac) = gcmWithJ0(key: nuraKey, j0: j0App, aad: challenge, plaintext: [])
        addLog("  app GMAC=\(hexStr(Data(appGmac)))")
        
        sendGaiaFrame(
            cmd: cmdCryptoValidateChallenge,
            payload: nonce + appGmac,
            expectedAck: cmdCryptoValidateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog("Handshake step 2 failed: \(e.localizedDescription)")
                self.abortForSafety("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoValidate status=\(s)")
                    self.abortForSafety("Handshake status \(s)")
                    return
                }
                let devGmac = Array(payload[1..<17])
                self.addLog("  device GMAC=\(hexStr(Data(devGmac)))")
                do {
                    let j0Dev = makeJ0(nonce: nonce, counter: 1, deviceToApp: true)
                    _ = try gcmOpenJ0(key: self.nuraKey, j0: j0Dev, aad: kyleAAD, ciphertext: [], tag: devGmac)
                    self.addLog("  Device GMAC verified - session established")
                    self.session = NuraSession(key: self.nuraKey, nonce: nonce)
                    self.runStartupSequence()
                } catch {
                    self.addLog("  Device GMAC mismatch - wrong key?")
                    self.abortForSafety("Crypto: wrong key")
                }
            }
        }
    }
    
    // MARK: - Startup sequence (matches NuraLib's CreateSafeStartupReads)
    
    private func runStartupSequence() {
        addLog("Reading initial state...")
        // Only the upstream-proven read set. The extra reads (ANC level,
        // spatial, button/dial config) were removed after they were implicated
        // in the device emitting a loud tone on connect.
        readCurrentProfileId { [weak self] in
            self?.readProfileNames {
                self?.readAncState {
                    self?.readKickitParams {
                        self?.readBattery {
                            self?.readKickitEnabled {
                                self?.finishStartup()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func finishStartup() {
        phase = .ready
        addLog("Ready")
        startBatteryTimer()
        if let serial = state.deviceInfo?.serialNumber {
            var config = configStore.load()
            config.lastConnectedSerial = String(serial)
            configStore.save(config)
            localProfileNames = loadProfileLabels(serial: serial)
        }
    }
    
    // MARK: - Local (app-side) profile names
    
    /// The primary name to show for a profile: a user-set app label, else the
    /// device's own name, else a numbered fallback.
    func displayProfileName(_ id: Int) -> String {
        localProfileNames[id] ?? state.profileNames[id] ?? "Profile \(id + 1)"
    }
    
    /// The parenthetical detail shown after a custom name: the device's own
    /// profile name if it has one, else the numbered fallback. Returns nil when
    /// there's no custom name (so nothing extra is shown).
    func profileNameDetail(_ id: Int) -> String? {
        guard localProfileNames[id] != nil else { return nil }
        return state.profileNames[id] ?? "Profile \(id + 1)"
    }
    
    /// Whether the device actually reported a profile in this slot. Slots the
    /// headphones report no name for are treated as empty.
    func isProfilePopulated(_ id: Int) -> Bool {
        state.profileNames[id] != nil
    }
    
    /// Renames a profile in the app only (no command is sent to the device).
    func renameProfile(_ id: Int, to name: String) {
        guard let serial = state.deviceInfo?.serialNumber else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = configStore.load()
        var labels = config.profileLabels ?? [:]
        let key = "\(serial).\(id)"
        if trimmed.isEmpty {
            labels[key] = nil
            localProfileNames[id] = nil
        } else {
            labels[key] = trimmed
            localProfileNames[id] = trimmed
        }
        config.profileLabels = labels
        configStore.save(config)
    }
    
    private func loadProfileLabels(serial: Int) -> [Int: String] {
        let all = configStore.load().profileLabels ?? [:]
        var out: [Int: String] = [:]
        for id in 0..<3 {
            if let name = all["\(serial).\(id)"] { out[id] = name }
        }
        return out
    }
    
    // MARK: - Profile visualisation
    
    /// Whether this device's firmware exposes the hearing-profile visualisation
    /// data. Per the reference capability map, the Nuraphone gains it only on
    /// firmware newer than 510. If we don't know the firmware yet, assume no.
    var supportsVisualisation: Bool {
        (state.deviceInfo?.firmwareVersion ?? 0) > 510
    }
    
    /// The connected device's product family, inferred from its serial number.
    /// `.unknown` before a device-info response has arrived.
    var family: NuraDeviceFamily {
        NuraDeviceFamily.forSerial(state.deviceInfo?.serialNumber)
    }
    
    /// Reads the visualisation for every populated profile in turn (used by the
    /// comparison view). Sequential because only one encrypted command is in
    /// flight at a time. Pure reads; nothing is played.
    func refreshAllVisualisations() {
        guard phase.isReady, supportsVisualisation else { return }
        let ids = [0, 1, 2].filter { isProfilePopulated($0) }
        readVisualisationChain(ids, index: 0)
    }
    
    private func readVisualisationChain(_ ids: [Int], index: Int) {
        guard index < ids.count else { return }
        let profileId = ids[index]
        sendEncrypted(opcode: cmdGetVisualisationData, params: [UInt8(profileId)]) { [weak self] result in
            if case .success(let pt) = result,
               let vis = NuraResponseParsers.decodeVisualisationData(pt) {
                self?.state.visualisations[profileId] = vis
                self?.addLog("<- visualisation loaded for profile \(profileId)")
            }
            self?.readVisualisationChain(ids, index: index + 1)
        }
    }
    
    // MARK: - Quick actions (used by global hotkeys)
    
    /// Steps immersion by delta, clamped to the device's supported range
    /// (-2...4 classic, -3...+3 on NuraTrue Pro). Returns the new level for
    /// feedback.
    @discardableResult
    func immersionStep(_ delta: Int) -> Int {
        let range = family == .nuraTruePro ? (-3...3) : (-2...4)
        let newLevel = max(range.lowerBound, min(range.upperBound, state.immersionLevel + delta))
        setImmersion(newLevel)
        return newLevel
    }
    
    /// Toggles noise control between its two extremes: the boolean
    /// ANC/Passthrough pair on the Nuraphone, or the 0...6 level continuum
    /// (below the midpoint jumps to full ANC, otherwise full social) on
    /// every device since NuraLoop.
    @discardableResult
    func toggleAncSocial() -> NuraAncMode {
        guard family.usesAncLevel else {
            let current = state.anc?.mode ?? .off
            let target: NuraAncMode = (current == .anc) ? .passthrough : .anc
            setAncMode(target)
            return target
        }
        if family == .nuraTruePro {
            // Default an unknown level to 6 so an uncertain toggle lands on
            // transparency, the safer default.
            let current = state.ancLevel ?? 6
            let target = current >= 4 ? 0 : 6
            setAncLevel(target)
            return target == 6 ? .anc : .passthrough
        }
        let current = state.ancLevel ?? 0
        let target = current >= 4 ? 0 : 6
        setAncLevel(target)
        return target >= 4 ? .passthrough : .anc
    }
    
    /// Cycles to the next/previous populated profile. Returns the profile id it
    /// switched to, or nil if there are none.
    @discardableResult
    func cycleProfile(forward: Bool) -> Int? {
        let ids = [0, 1, 2].filter { isProfilePopulated($0) }
        guard !ids.isEmpty else { return nil }
        let current = state.profileId ?? ids[0]
        let idx = ids.firstIndex(of: current) ?? 0
        let nextIdx = forward ? (idx + 1) % ids.count : (idx - 1 + ids.count) % ids.count
        let target = ids[nextIdx]
        selectProfile(target)
        return target
    }
    
    /// Reads a profile's hearing-signature visualisation on demand. This is a
    /// pure read (0x00B8): it fetches stored numbers and plays nothing. It is
    /// never part of the automatic connect sequence - only the user tapping to
    /// view a profile triggers it.
    func refreshVisualisation(profileId: Int) {
        guard phase.isReady else { return }
        guard supportsVisualisation else {
            addLog("Visualisation not supported on this firmware")
            return
        }
        addLog("-> GetVisualisationData profile \(profileId) (requested)")
        sendEncrypted(opcode: cmdGetVisualisationData, params: [UInt8(profileId)]) { [weak self] result in
            switch result {
            case .success(let pt):
                if let vis = NuraResponseParsers.decodeVisualisationData(pt) {
                    self?.state.visualisations[profileId] = vis
                    self?.addLog("<- visualisation loaded for profile \(profileId) (valid=\(vis.valid))")
                } else {
                    self?.addLog("<- visualisation: unexpected payload (\(pt.count) bytes)")
                }
            case .failure(let e):
                self?.addLog("<- visualisation error: \(e.localizedDescription)")
            }
        }
    }
    
    /// Reads the current button configuration on demand (used by the remap
    /// screen). Not part of the automatic connect sequence.
    func refreshButtonConfig() {
        guard phase.isReady else { return }
        let caps = NuraButtonCapabilities.for(family)
        addLog("-> GetButtonConfig (requested)")
        sendEncrypted(opcode: cmdGetButtonConfigV1, params: [UInt8(state.profileId ?? 0)]) { [weak self] result in
            if case .success(let pt) = result,
               let config = NuraResponseParsers.decodeButtonConfiguration(
                pt, supportsDoubleTap: caps.supportsDoubleTap, supportsTripleTap: caps.supportsTripleTap
               ) {
                self?.state.buttons = config
                self?.addLog("<- button config loaded")
            } else {
                self?.addLog("<- button config: no data")
            }
        }
    }
    
    private func readCurrentProfileId(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetCurrentProfileId, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let id = NuraResponseParsers.decodeCurrentProfileId(pt) {
                self?.state.profileId = id
                self?.addLog("  profile = \(id)")
            }
            next()
        }
    }
    
    private func readProfileNames(then next: @escaping () -> Void) {
        readProfileName(id: 0) { [weak self] in
            self?.readProfileName(id: 1) {
                self?.readProfileName(id: 2) {
                    next()
                }
            }
        }
    }
    
    private func readProfileName(id: Int, then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetProfileName, params: [UInt8(id)]) { [weak self] result in
            if case .success(let pt) = result,
               let name = NuraResponseParsers.decodeProfileName(pt) {
                self?.state.profileNames[id] = name
                self?.addLog("  profile[\(id)] = \"\(name)\"")
            }
            next()
        }
    }
    
    private func readAncState(then next: @escaping () -> Void) {
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdGetAncState, params: [profileId]) { [weak self] result in
            if case .success(let pt) = result,
               let ancState = NuraResponseParsers.decodeAncState(pt) {
                self?.state.anc = ancState
                self?.addLog("  ANC=\(ancState.ancEnabled ? "ON" : "OFF") social=\(ancState.passthroughEnabled ? "ON" : "OFF")")
            }
            next()
        }
    }
    
    private func readKickitParams(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetKickitParams, params: [UInt8(state.profileId ?? 0)]) { [weak self] result in
            if case .success(let pt) = result,
               let params = NuraResponseParsers.decodeClassicKickitParams(pt),
               let level = params.immersionLevel {
                self?.state.immersionLevel = level.rawValue
                self?.addLog("  immersion = \(level.rawValue)")
            }
            next()
        }
    }
    
    private func readBattery(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetBatteryStatus, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let battery = NuraResponseParsers.decodeBatteryStatus(pt) {
                self?.state.battery = battery
                self?.addLog("  battery = \(battery.batteryPercentage)%\(battery.isCharging ? " (charging)" : "")")
            }
            next()
        }
    }
    
    private func readKickitEnabled(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetKickitEnabled, params: [UInt8(state.profileId ?? 0)]) { [weak self] result in
            if case .success(let pt) = result,
               let enabled = NuraResponseParsers.decodeBooleanFlag(pt) {
                self?.state.kickitEnabled = enabled
                self?.addLog("  kickit enabled = \(enabled)")
            }
            next()
        }
    }
}

// MARK: - NuraTransportDelegate

extension NuraDeviceManager: NuraTransportDelegate {
    func transportDidSelectDevice(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        connectedDeviceName = trimmed.isEmpty ? "Nura device" : trimmed
    }
    
    func transportDidUpdatePhase(_ newPhase: ConnectionPhase) {
        switch newPhase {
        case .handshaking:
            phase = .handshaking
            runGaiaSequence()
        case .failed(let msg):
            session = nil
            gaiaCommandBusy = false
            phase = .failed(msg)
        case .connecting:
            phase = .connecting
        case .discovering:
            phase = .discovering
        case .scanning:
            phase = .scanning
        case .idle:
            if phase != .idle {
                session = nil
                gaiaCommandBusy = false
                phase = .idle
            }
        case .ready:
            break
        }
    }
    
    func transportDidReceiveIndication(_ response: GaiaResponse) {
        if let indication = HeadsetIndicationParser.parse(response) {
            handleIndication(indication)
        }
        
        var logLine = String(
            format: "<- event 0x%04x payload=%@",
            response.rawCommandId, hexStr(Data(response.payload))
        )
        if let desc = gaiaEventDescription(response.payload) { logLine += "  [\(desc)]" }
        addLog(logLine)
    }
    
    func transportDidLog(_ message: String) {
        addLog(message)
    }
    
    private func handleIndication(_ indication: HeadsetIndication) {
        switch indication.identifier {
        case .ancParametersChanged:
            let ancState = HeadsetIndicationParser.decodeNuraphoneAncState(indication.value)
            state.anc = ancState
        case .ancLevelChanged:
            state.ancLevel = Int(indication.value)
        case .currentProfileChanged:
            state.profileId = Int(indication.value)
        case .kickitEnabledChanged:
            state.personalisationMode = indication.value != 0 ? .personalised : .neutral
        case .kickitLevelChanged:
            state.immersionLevel = Int(indication.value)
        default:
            break
        }
    }
}
