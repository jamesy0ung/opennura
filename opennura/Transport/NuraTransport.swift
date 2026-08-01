import Foundation

protocol NuraTransportDelegate: AnyObject {
    func transportDidSelectDevice(named name: String)
    func transportDidUpdatePhase(_ phase: ConnectionPhase)
    func transportDidReceiveIndication(_ response: GaiaResponse)
    func transportDidLog(_ message: String)
}

protocol NuraTransport: AnyObject {
    var delegate: NuraTransportDelegate? { get set }
    var phase: ConnectionPhase { get }
    /// When true, if the headphones are currently connected for audio the
    /// transport disconnects that link itself before opening the control
    /// channel (so the user doesn't have to do it in Bluetooth settings).
    /// Only the classic-Bluetooth (macOS) transport acts on this.
    var autoResetOnConnect: Bool { get set }
    func scan()
    func stopScan()
    func disconnect()
    func sendFrame(_ frame: GaiaFrame, expectedAck: UInt16, minResponseLen: Int, completion: @escaping (Result<[UInt8], Error>) -> Void)
    /// Sends a raw GAIA command and resolves with the next non-indication
    /// response frame, regardless of its command id. Used by the provisioning
    /// relay, which forwards backend-issued packets and returns whatever the
    /// device replies. Only one send (framed or raw) may be in flight at a time.
    func sendRawFrameCapturingResponse(commandId: UInt16, payload: [UInt8], completion: @escaping (Result<GaiaResponse, Error>) -> Void)
}
