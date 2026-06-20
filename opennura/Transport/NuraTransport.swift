import Foundation

enum TransportType: String, CaseIterable, Identifiable {
    case ble = "Bluetooth LE"
    case classic = "Classic Bluetooth"
    var id: String { rawValue }
}

protocol NuraTransportDelegate: AnyObject {
    func transportDidUpdatePhase(_ phase: ConnectionPhase)
    func transportDidReceiveIndication(_ response: GaiaResponse)
    func transportDidLog(_ message: String)
}

protocol NuraTransport: AnyObject {
    var delegate: NuraTransportDelegate? { get set }
    var phase: ConnectionPhase { get }
    func scan()
    func stopScan()
    func disconnect()
    func sendFrame(_ frame: GaiaFrame, expectedAck: UInt16, minResponseLen: Int, completion: @escaping (Result<[UInt8], Error>) -> Void)
}
