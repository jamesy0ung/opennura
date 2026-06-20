import Combine
import Foundation

@MainActor
final class NuraDeviceState: ObservableObject {
    @Published var deviceInfo: NuraDeviceInfo?
    @Published var anc: NuraAncState?
    @Published var ancLevel: Int?
    @Published var globalAncEnabled: Bool?
    @Published var battery: NuraBatteryStatus?
    @Published var spatialEnabled: Bool?
    @Published var immersionLevel: Int = 0
    @Published var personalisationMode: NuraPersonalisationMode = .personalised
    @Published var profileId: Int?
    @Published var profileNames: [Int: String] = [:]
    @Published var buttons: NuraButtonConfiguration?
    @Published var dial: NuraDialConfiguration?
    @Published var kickitEnabled: Bool?

    var ancEnabled: Bool { anc?.ancEnabled ?? false }
    var passthroughEnabled: Bool { anc?.passthroughEnabled ?? false }
    var batteryPercentage: Int? { battery?.batteryPercentage }

    func reset() {
        deviceInfo = nil
        anc = nil
        ancLevel = nil
        globalAncEnabled = nil
        battery = nil
        spatialEnabled = nil
        immersionLevel = 0
        personalisationMode = .personalised
        profileId = nil
        profileNames = [:]
        buttons = nil
        dial = nil
        kickitEnabled = nil
    }
}
