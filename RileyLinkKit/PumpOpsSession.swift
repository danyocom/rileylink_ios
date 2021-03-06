//
//  PumpOpsSynchronous.swift
//  RileyLink
//
//  Created by Pete Schwamb on 3/12/16.
//  Copyright © 2016 Pete Schwamb. All rights reserved.
//

import Foundation
import MinimedKit
import RileyLinkBLEKit


protocol PumpOpsSessionDelegate: class {
    func pumpOpsSession(_ session: PumpOpsSession, didChange state: PumpState)
}


public class PumpOpsSession {

    private var pump: PumpState {
        didSet {
            delegate.pumpOpsSession(self, didChange: pump)
        }
    }
    private let settings: PumpSettings
    private let session: PumpMessageSender

    private unowned let delegate: PumpOpsSessionDelegate
    
    internal init(settings: PumpSettings, pumpState: PumpState, session: PumpMessageSender, delegate: PumpOpsSessionDelegate) {
        self.settings = settings
        self.pump = pumpState
        self.session = session
        self.delegate = delegate
    }
}


// MARK: - Wakeup and power
extension PumpOpsSession {
    private static let minimumTimeBetweenWakeAttempts = TimeInterval(minutes: 1)

    /// Attempts to send initial short wakeup message that kicks off the wakeup process.
    ///
    /// If successful, still does not fully wake up the pump - only alerts it such that the longer wakeup message can be sent next.
    ///
    /// - Throws:
    ///     - PumpCommandError.command containing:
    ///         - PumpOpsError.crosstalk
    ///         - PumpOpsError.deviceError
    ///         - PumpOpsError.noResponse
    ///         - PumpOpsError.unexpectedResponse
    ///         - PumpOpsError.unknownResponse
    private func sendWakeUpBurst() throws {
        // Skip waking up if we recently tried
        guard pump.lastWakeAttempt == nil || pump.lastWakeAttempt!.timeIntervalSinceNow <= -PumpOpsSession.minimumTimeBetweenWakeAttempts
        else {
            return
        }

        pump.lastWakeAttempt = Date()

        let shortPowerMessage = PumpMessage(settings: settings, type: .powerOn)

        if pump.pumpModel == nil || !pump.pumpModel!.hasMySentry {
            // Older pumps have a longer sleep cycle between wakeups, so send an initial burst
            do {
                let _: PumpAckMessageBody = try session.getResponse(to: shortPowerMessage, repeatCount: 255, timeout: .milliseconds(1), retryCount: 0)
            }
            catch { }
        }

        do {
            let _: PumpAckMessageBody = try session.getResponse(to: shortPowerMessage, repeatCount: 255, timeout: .seconds(12), retryCount: 0)
        } catch let error as PumpOpsError {
            throw PumpCommandError.command(error)
        }
    }

    private func isPumpResponding() -> Bool {
        do {
            let _: GetPumpModelCarelinkMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .getPumpModel), responseType: .getPumpModel, retryCount: 1)
            return true
        } catch {
            return false
        }
    }

    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///         - PumpOpsError.crosstalk
    ///         - PumpOpsError.deviceError
    ///         - PumpOpsError.noResponse
    ///         - PumpOpsError.unexpectedResponse
    ///         - PumpOpsError.unknownResponse
    private func wakeup(_ duration: TimeInterval = TimeInterval(minutes: 1)) throws {
        guard !pump.isAwake else {
            return
        }

        // Send a short message to the pump to see if its radio is still powered on
        if isPumpResponding() {
            // TODO: Convert logging
            NSLog("Pump responding despite our wake timer having expired. Extending timer")
            // By my observations, the pump stays awake > 1 minute past last comms. Usually
            // About 1.5 minutes, but we'll make it a minute to be safe.
            pump.awakeUntil = Date(timeIntervalSinceNow: TimeInterval(minutes: 1))
            return
        }

        // Command
        try sendWakeUpBurst()

        // Arguments
        do {
            let longPowerMessage = PumpMessage(settings: settings, type: .powerOn, body: PowerOnCarelinkMessageBody(duration: duration))
            let _: PumpAckMessageBody = try session.getResponse(to: longPowerMessage)
        } catch let error as PumpOpsError {
            throw PumpCommandError.arguments(error)
        } catch {
            assertionFailure()
        }

        // TODO: Convert logging
        NSLog("Power on for %.0f minutes", duration.minutes)
        pump.awakeUntil = Date(timeIntervalSinceNow: duration)
    }
}

// MARK: - Single reads
extension PumpOpsSession {
    /// Retrieves the pump model from either the state or from the
    ///
    /// - Parameter usingCache: Whether the pump state should be checked first for a known pump model
    /// - Returns: The pump model
    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func getPumpModel(usingCache: Bool = true) throws -> PumpModel {
        if usingCache, let pumpModel = pump.pumpModel {
            return pumpModel
        }

        try wakeup()
        let body: GetPumpModelCarelinkMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .getPumpModel), responseType: .getPumpModel)

        guard let pumpModel = PumpModel(rawValue: body.model) else {
            throw PumpOpsError.unknownPumpModel(body.model)
        }

        pump.pumpModel = pumpModel

        return pumpModel
    }

    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func getBatteryStatus() throws -> GetBatteryCarelinkMessageBody {
        try wakeup()
        return try session.getResponse(to: PumpMessage(settings: settings, type: .getBattery), responseType: .getBattery)
    }

    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    internal func getPumpStatus() throws -> ReadPumpStatusMessageBody {
        try wakeup()
        return try session.getResponse(to: PumpMessage(settings: settings, type: .readPumpStatus), responseType: .readPumpStatus)
    }

    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func getSettings() throws -> ReadSettingsCarelinkMessageBody {
        try wakeup()
        return try session.getResponse(to: PumpMessage(settings: settings, type: .readSettings), responseType: .readSettings)
    }

    /// Reads the pump's time, returning a set of DateComponents in the pump's presumed time zone.
    ///
    /// - Returns: The pump's time components including timeZone
    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func getTime() throws -> DateComponents {
        try wakeup()
        let response: ReadTimeCarelinkMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .readTime), responseType: .readTime)
        var components = response.dateComponents
        components.timeZone = pump.timeZone
        return components
    }

    /// Reads Basal Schedule from the pump
    ///
    /// - Returns: The pump's standard basal schedule
    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func getBasalSchedule(for profile: BasalProfile = .standard) throws -> BasalSchedule {
        try wakeup()

        var isFinished = false
        var message = PumpMessage(settings: settings, type: profile.readMessageType)
        var scheduleData = Data()
        while (!isFinished) {
            let body: DataFrameMessageBody = try session.getResponse(to: message, responseType: profile.readMessageType)

            scheduleData.append(body.contents)
            isFinished = body.isLastFrame
            message = PumpMessage(settings: settings, type: .pumpAck)
        }

        return BasalSchedule(rawValue: scheduleData)!
    }
}


// MARK: - Aggregate reads
public struct PumpStatus {
    // Date components read from the pump, along with PumpState.timeZone
    public let clock: DateComponents
    public let batteryVolts: Double
    public let batteryStatus: BatteryStatus
    public let suspended: Bool
    public let bolusing: Bool
    public let reservoir: Double
    public let model: PumpModel
    public let pumpID: String
}


extension PumpOpsSession {
    /// Reads the current insulin reservoir volume and the pump's date
    ///
    /// - Returns:
    ///     - The reservoir volume, in units of insulin
    ///     - DateCompoments representing the pump's clock
    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unknownResponse
    public func getRemainingInsulin() throws -> (units: Double, clock: DateComponents) {

        let pumpModel = try getPumpModel()
        let pumpClock = try getTime()

        let reservoir: ReadRemainingInsulinMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .readRemainingInsulin), responseType: .readRemainingInsulin)

        return (
            units: reservoir.getUnitsRemainingForStrokes(pumpModel.strokesPerUnit),
            clock: pumpClock
        )
    }

    /// Reads clock, reservoir, battery, bolusing, and suspended state from pump
    ///
    /// - Returns: The pump status
    /// - Throws:
    ///     - PumpCommandError
    ///     - PumpOpsError
    public func getCurrentPumpStatus() throws -> PumpStatus {
        let pumpModel = try getPumpModel()

        let battResp = try getBatteryStatus()

        let status = try getPumpStatus()

        let (reservoir, clock) = try getRemainingInsulin()

        return PumpStatus(
            clock: clock,
            batteryVolts: battResp.volts,
            batteryStatus: battResp.status,
            suspended: status.suspended,
            bolusing: status.bolusing,
            reservoir: reservoir,
            model: pumpModel,
            pumpID: settings.pumpID
        )
    }
}


// MARK: - Command messages
extension PumpOpsSession {
    /// - Throws: `PumpCommandError` specifying the failure sequence
    private func runCommandWithArguments<T: MessageBody>(_ message: PumpMessage, responseType: MessageType = .pumpAck) throws -> T {
        do {
            try wakeup()

            let shortMessage = PumpMessage(packetType: message.packetType, address: message.address.hexadecimalString, messageType: message.messageType, messageBody: CarelinkShortMessageBody())
            let _: PumpAckMessageBody = try session.getResponse(to: shortMessage)
        } catch let error as PumpOpsError {
            throw PumpCommandError.command(error)
        }

        do {
            return try session.getResponse(to: message, responseType: responseType)
        } catch let error as PumpOpsError {
            throw PumpCommandError.arguments(error)
        }
    }

    /// - Throws: `PumpCommandError` specifying the failure sequence
    public func pressButton(_ type: ButtonPressCarelinkMessageBody.ButtonType) throws {
        let message = PumpMessage(settings: settings, type: .buttonPress, body: ButtonPressCarelinkMessageBody(buttonType: type))

        let _: PumpAckMessageBody = try runCommandWithArguments(message)
    }

    /// - Throws: PumpCommandError
    public func selectBasalProfile(_ profile: BasalProfile) throws {
        let message = PumpMessage(settings: settings, type: .selectBasalProfile, body: SelectBasalProfileMessageBody(newProfile: profile))

        let _: PumpAckMessageBody = try runCommandWithArguments(message)
    }

    /// Changes the current temporary basal rate
    ///
    /// - Parameters:
    ///   - unitsPerHour: The new basal rate, in Units per hour
    ///   - duration: The duration of the rate
    /// - Returns: The pump message body describing the new basal rate
    /// - Throws: PumpCommandError
    public func setTempBasal(_ unitsPerHour: Double, duration: TimeInterval) throws -> ReadTempBasalCarelinkMessageBody {
        var lastError: Error?
        
        let message = PumpMessage(settings: settings, type: .changeTempBasal, body: ChangeTempBasalCarelinkMessageBody(unitsPerHour: unitsPerHour, duration: duration))

        for attempt in 1..<4 {
            do {
                do {
                    try wakeup()

                    let shortMessage = PumpMessage(packetType: message.packetType, address: message.address.hexadecimalString, messageType: message.messageType, messageBody: CarelinkShortMessageBody())
                    let _: PumpAckMessageBody = try session.getResponse(to: shortMessage)
                } catch let error as PumpOpsError {
                    throw PumpCommandError.command(error)
                }

                do {
                    let _: PumpAckMessageBody = try session.getResponse(to: message, retryCount: 0)
                } catch PumpOpsError.pumpError(let errorCode) {
                    lastError = PumpCommandError.arguments(.pumpError(errorCode))
                    break  // Stop because we have a pump error response
                } catch PumpOpsError.unknownPumpErrorCode(let errorCode) {
                    lastError = PumpCommandError.arguments(.unknownPumpErrorCode(errorCode))
                    break  // Stop because we have a pump error response
                } catch {
                    // The pump does not ACK a successful temp basal. We'll check manually below if it was successful.
                }

                let response: ReadTempBasalCarelinkMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .readTempBasal), responseType: .readTempBasal)

                if response.timeRemaining == duration && response.rateType == .absolute {
                    return response
                } else {
                    throw PumpCommandError.arguments(PumpOpsError.rfCommsFailure("Could not verify TempBasal on attempt \(attempt). "))
                }
            } catch let error {
                lastError = error
            }
        }

        throw lastError ?? PumpOpsError.noResponse(during: "Set temp basal")
    }

    /// Changes the pump's clock to the specified date components in the system time zone
    ///
    /// - Parameter generator: A closure which returns the desired date components. An exeception is raised if the date components are not valid.
    /// - Throws: PumpCommandError
    public func setTime(_ generator: () -> DateComponents) throws {
        try wakeup()

        do {
            let shortMessage = PumpMessage(settings: settings, type: .changeTime)
            let _: PumpAckMessageBody = try session.getResponse(to: shortMessage)
        } catch let error as PumpOpsError {
            throw PumpCommandError.command(error)
        }

        do {
            let message = PumpMessage(settings: settings, type: .changeTime, body: ChangeTimeCarelinkMessageBody(dateComponents: generator())!)
            let _: PumpAckMessageBody = try session.getResponse(to: message)
            self.pump.timeZone = .currentFixed
        } catch let error as PumpOpsError {
            throw PumpCommandError.arguments(error)
        }
    }

    /// Sets a bolus
    ///
    /// *Note: Use at your own risk!*
    ///
    /// - Parameters:
    ///   - units: The number of units to deliver
    ///   - cancelExistingTemp: If true, additional pump commands will be issued to clear any running temp basal. Defaults to false.
    /// - Throws: SetBolusError describing the certainty of the underlying error
    public func setNormalBolus(units: Double, cancelExistingTemp: Bool = false) throws {
        let pumpModel: PumpModel

        do {
            try wakeup()
            pumpModel = try getPumpModel()

            let status = try getPumpStatus()

            if status.bolusing {
                throw PumpOpsError.bolusInProgress
            }

            if status.suspended {
                throw PumpOpsError.pumpSuspended
            }

            if cancelExistingTemp {
                _ = try setTempBasal(0, duration: 0)
            }
        } catch let error as PumpOpsError {
            throw SetBolusError.certain(error)
        } catch let error as PumpCommandError {
            switch error {
            case .command(let error):
                throw SetBolusError.certain(error)
            case .arguments(let error):
                throw SetBolusError.certain(error)
            }
        } catch {
            assertionFailure()
            return
        }

        do {
            let message = PumpMessage(settings: settings, type: .bolus, body: BolusCarelinkMessageBody(units: units, strokesPerUnit: pumpModel.strokesPerUnit))

            if pumpModel.returnsErrorOnBolus {
                // TODO: This isn't working as expected; this logic was probably intended to be in the catch block below
                let error: PumpErrorMessageBody = try runCommandWithArguments(message, responseType: .errorResponse)

                switch error.errorCode {
                case .known(let errorCode):
                    if errorCode != .bolusInProgress {
                        throw PumpOpsError.pumpError(errorCode)
                    }
                case .unknown(let unknownErrorCode):
                    throw PumpOpsError.unknownPumpErrorCode(unknownErrorCode)
                }
            } else {
                let _: PumpAckMessageBody = try runCommandWithArguments(message)
            }
        } catch let error as PumpOpsError {
            throw SetBolusError.certain(error)
        } catch let error as PumpCommandError {
            switch error {
            case .command(let error):
                throw SetBolusError.certain(error)
            case .arguments(let error):
                throw SetBolusError.uncertain(error)
            }
        } catch {
            assertionFailure()
        }
        return
    }

    /// - Throws: `PumpCommandError` specifying the failure sequence
    public func setBasalSchedule(_ basalSchedule: BasalSchedule, for profile: BasalProfile, type: MessageType) throws {


        let frames = DataFrameMessageBody.dataFramesFromContents(basalSchedule.rawValue)

        guard let firstFrame = frames.first else {
            return
        }

        NSLog(firstFrame.txData.hexadecimalString)

        let message = PumpMessage(settings: settings, type: type, body: firstFrame)
        let _: PumpAckMessageBody = try runCommandWithArguments(message)

        for nextFrame in frames.dropFirst() {
            let message = PumpMessage(settings: settings, type: type, body: nextFrame)
            NSLog(nextFrame.txData.hexadecimalString)
            do {
                let _: PumpAckMessageBody = try session.getResponse(to: message)
            } catch let error as PumpOpsError {
                throw PumpCommandError.arguments(error)
            }
        }
    }

    public func discoverCommands(_ updateHandler: (_ messages: [String]) -> Void) {
        let codes: [MessageType] = [
            .PumpExperiment_O103,
        ]

        for code in codes {
            var messages = [String]()

            do {
                messages.append(contentsOf: [
                    "## Command \(code)",
                ])

                try wakeup()

                // Try the short command message, without any arguments.
                let shortMessage = PumpMessage(settings: settings, type: code)
                let _: PumpAckMessageBody = try session.getResponse(to: shortMessage)

                messages.append(contentsOf: [
                    "Succeeded",
                    ""
                ])

                // Check history?

            } catch let error {
                messages.append(contentsOf: [
                    String(describing: error),
                    "",
                ])
            }

            updateHandler(messages)

            Thread.sleep(until: Date(timeIntervalSinceNow: 2))
        }
    }
}


// MARK: - MySentry (Watchdog) pairing
extension PumpOpsSession {
    /// Pairs the pump with a virtual "watchdog" device to enable it to broadcast periodic status packets. Only pump models x23 and up are supported.
    ///
    /// - Parameter watchdogID: A 3-byte address for the watchdog device.
    /// - Throws:
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unexpectedResponse
    ///     - PumpOpsError.unknownResponse
    public func changeWatchdogMarriageProfile(_ watchdogID: Data) throws {
        try setRXFilterMode(.wide)
        defer {
            do {
                try configureRadio(for: settings.pumpRegion)
            } catch {
                // Best effort resetting radio filter mode
            }
        }

        let commandTimeout = TimeInterval(seconds: 30)

        // Wait for the pump to start polling
        guard let encodedData = try session.listenForPacket(onChannel: 0, timeout: commandTimeout)?.data else {
            throw PumpOpsError.noResponse(during: "Watchdog listening")
        }

        guard let packet = MinimedPacket(encodedData: encodedData) else {
            // TODO: Change error to better reflect that this is an encoding or CRC error
            throw PumpOpsError.unknownResponse(rx: encodedData, during: "Watchdog listening")
        }
        
        guard let findMessage = PumpMessage(rxData: packet.data) else {
            // Unknown packet type or message type
            throw PumpOpsError.unknownResponse(rx: packet.data, during: "Watchdog listening")
        }

        guard findMessage.address.hexadecimalString == settings.pumpID && findMessage.packetType == .mySentry,
            let findMessageBody = findMessage.messageBody as? FindDeviceMessageBody, let findMessageResponseBody = MySentryAckMessageBody(sequence: findMessageBody.sequence, watchdogID: watchdogID, responseMessageTypes: [findMessage.messageType])
        else {
            throw PumpOpsError.unknownResponse(rx: packet.data, during: "Watchdog listening")
        }

        // Identify as a MySentry device
        let findMessageResponse = PumpMessage(packetType: .mySentry, address: settings.pumpID, messageType: .pumpAck, messageBody: findMessageResponseBody)

        let linkMessage = try session.sendAndListen(findMessageResponse, timeout: commandTimeout)

        guard let
            linkMessageBody = linkMessage.messageBody as? DeviceLinkMessageBody,
            let linkMessageResponseBody = MySentryAckMessageBody(sequence: linkMessageBody.sequence, watchdogID: watchdogID, responseMessageTypes: [linkMessage.messageType])
        else {
            throw PumpOpsError.unexpectedResponse(linkMessage, from: findMessageResponse)
        }

        // Acknowledge the pump linked with us
        let linkMessageResponse = PumpMessage(packetType: .mySentry, address: settings.pumpID, messageType: .pumpAck, messageBody: linkMessageResponseBody)

        try session.send(linkMessageResponse)
    }
}


// MARK: - Tuning
private extension PumpRegion {
    var scanFrequencies: [Measurement<UnitFrequency>] {
        let scanFrequencies: [Double]

        switch self {
        case .worldWide:
            scanFrequencies = [868.25, 868.30, 868.35, 868.40, 868.45, 868.50, 868.55, 868.60, 868.65]
        case .northAmerica:
            scanFrequencies = [916.45, 916.50, 916.55, 916.60, 916.65, 916.70, 916.75, 916.80]
        }

        return scanFrequencies.map {
            return Measurement<UnitFrequency>(value: $0, unit: .megahertz)
        }
    }
}

enum RXFilterMode: UInt8 {
    case wide   = 0x50  // 300KHz
    case narrow = 0x90  // 150KHz
}

public struct FrequencyTrial {
    public var tries: Int = 0
    public var successes: Int = 0
    public var avgRSSI: Double = -99
    public var frequency: Measurement<UnitFrequency>

    init(frequency: Measurement<UnitFrequency>) {
        self.frequency = frequency
    }
}

public struct FrequencyScanResults {
    public var trials: [FrequencyTrial]
    public var bestFrequency: Measurement<UnitFrequency>
}

extension PumpOpsSession {
    /// - Throws:
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.rfCommsFailure
    public func tuneRadio(current: Measurement<UnitFrequency>?) throws -> FrequencyScanResults {
        let region = self.settings.pumpRegion

        do {
            let results = try scanForPump(in: region.scanFrequencies, current: current)

            return results
        } catch let error as PumpOpsError {
            throw error
        } catch let error as LocalizedError {
            throw PumpOpsError.deviceError(error)
        }
    }

    /// - Throws: PumpOpsError.deviceError
    private func setRXFilterMode(_ mode: RXFilterMode) throws {
        let drate_e = UInt8(0x9) // exponent of symbol rate (16kbps)
        let chanbw = mode.rawValue
        do {
            try session.updateRegister(.mdmcfg4, value: chanbw | drate_e)
        } catch let error as LocalizedError {
            throw PumpOpsError.deviceError(error)
        }
    }

    /// - Throws:
    ///     - PumpOpsError.deviceError
    ///     - RileyLinkDeviceError
    func configureRadio(for region: PumpRegion) throws {
        try session.resetRadioConfig()
        
        switch region {
        case .worldWide:
            //try session.updateRegister(.mdmcfg4, value: 0x59)
            try setRXFilterMode(.wide)
            //try session.updateRegister(.mdmcfg3, value: 0x66)
            //try session.updateRegister(.mdmcfg2, value: 0x33)
            try session.updateRegister(.mdmcfg1, value: 0x62)
            try session.updateRegister(.mdmcfg0, value: 0x1A)
            try session.updateRegister(.deviatn, value: 0x13)
        case .northAmerica:
            //try session.updateRegister(.mdmcfg4, value: 0x99)
            try setRXFilterMode(.narrow)
            //try session.updateRegister(.mdmcfg3, value: 0x66)
            //try session.updateRegister(.mdmcfg2, value: 0x33)
            try session.updateRegister(.mdmcfg1, value: 0x61)
            try session.updateRegister(.mdmcfg0, value: 0x7E)
            try session.updateRegister(.deviatn, value: 0x15)
        }
    }

    /// - Throws:
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.rfCommsFailure
    private func scanForPump(in frequencies: [Measurement<UnitFrequency>], current: Measurement<UnitFrequency>?) throws -> FrequencyScanResults {
        
        var trials = [FrequencyTrial]()
        
        let middleFreq = frequencies[frequencies.count / 2]
        
        do {
            // Needed to put the pump in listen mode
            try session.setBaseFrequency(middleFreq)
            try wakeup()
        } catch {
            // Continue anyway; the pump likely heard us, even if we didn't hear it.
        }
        
        for freq in frequencies {
            let tries = 3
            var trial = FrequencyTrial(frequency: freq)

            try session.setBaseFrequency(freq)
            var sumRSSI = 0
            for _ in 1...tries {
                // Ignore failures here
                let rfPacket = try? session.sendAndListenForPacket(PumpMessage(settings: settings, type: .getPumpModel))
                if  let rfPacket = rfPacket,
                    let pkt = MinimedPacket(encodedData: rfPacket.data),
                    let response = PumpMessage(rxData: pkt.data), response.messageType == .getPumpModel
                {
                    sumRSSI += rfPacket.rssi
                    trial.successes += 1
                }
                trial.tries += 1
            }
            // Mark each failure as a -99 rssi, so we can use highest rssi as best freq
            sumRSSI += -99 * (trial.tries - trial.successes)
            trial.avgRSSI = Double(sumRSSI) / Double(trial.tries)
            trials.append(trial)
        }
        let sortedTrials = trials.sorted(by: { (a, b) -> Bool in
            return a.avgRSSI > b.avgRSSI
        })

        guard sortedTrials.first!.successes > 0 else {
            try session.setBaseFrequency(current ?? middleFreq)
            throw PumpOpsError.rfCommsFailure("No pump responses during scan")
        }

        let results = FrequencyScanResults(
            trials: trials,
            bestFrequency: sortedTrials.first!.frequency
        )

        try session.setBaseFrequency(results.bestFrequency)

        return results
    }
}


// MARK: - Pump history
extension PumpOpsSession {
    /// Fetches history entries which occurred on or after the specified date.
    ///
    /// It is possible for Minimed Pumps to non-atomically append multiple history entries with the same timestamp, for example, `BolusWizardEstimatePumpEvent` may appear and be read before `BolusNormalPumpEvent` is written. Therefore, the `startDate` parameter is used as part of an inclusive range, leaving the client to manage the possibility of duplicates.
    ///
    /// History timestamps are reconciled with UTC based on the `timeZone` property of PumpState, as well as recorded clock change events.
    ///
    /// - Parameter startDate: The earliest date of events to retrieve
    /// - Returns:
    ///     - An array of fetched history entries, in ascending order of insertion
    ///     - The pump model
    /// - Throws:
    ///     - PumpCommandError.command
    ///     - PumpCommandError.arguments
    ///     - PumpOpsError.crosstalk
    ///     - PumpOpsError.deviceError
    ///     - PumpOpsError.noResponse
    ///     - PumpOpsError.unknownResponse
    public func getHistoryEvents(since startDate: Date) throws -> ([TimestampedHistoryEvent], PumpModel) {
        try wakeup()

        let pumpModel = try getPumpModel()
        
        var events = [TimestampedHistoryEvent]()
        
        pages: for pageNum in 0..<16 {
            // TODO: Convert logging
            NSLog("Fetching page %d", pageNum)
            let pageData: Data

            do {
                pageData = try getHistoryPage(pageNum)
            } catch PumpOpsError.pumpError {
                break pages
            }
            
            var idx = 0
            let chunkSize = 256
            while idx < pageData.count {
                let top = min(idx + chunkSize, pageData.count)
                let range = Range(uncheckedBounds: (lower: idx, upper: top))
                // TODO: Convert logging
                NSLog(String(format: "HistoryPage %02d - (bytes %03d-%03d): ", pageNum, idx, top-1) + pageData.subdata(in: range).hexadecimalString)
                idx = top
            }

            let page = try HistoryPage(pageData: pageData, pumpModel: pumpModel)
            
            let (timestampedEvents, hasMoreEvents, _) = page.timestampedEvents(after: startDate, timeZone: pump.timeZone, model: pumpModel)

            events = timestampedEvents + events
            
            if !hasMoreEvents {
                break
            }
        }
        return (events, pumpModel)
    }
    
    private func getHistoryPage(_ pageNum: Int) throws -> Data {
        var frameData = Data()
        
        let msg = PumpMessage(settings: settings, type: .getHistoryPage, body: GetHistoryPageCarelinkMessageBody(pageNum: pageNum))
        
        var curResp: GetHistoryPageCarelinkMessageBody = try runCommandWithArguments(msg, responseType: .getHistoryPage)

        var expectedFrameNum = 1
        
        while(expectedFrameNum == curResp.frameNumber) {
            frameData.append(curResp.frame)
            expectedFrameNum += 1
            let msg = PumpMessage(settings: settings, type: .pumpAck)
            if !curResp.lastFrame {
                curResp = try session.getResponse(to: msg, responseType: .getHistoryPage)
            } else {
                try session.send(msg)
                break
            }
        }
        
        guard frameData.count == 1024 else {
            throw PumpOpsError.rfCommsFailure("Short history page: \(frameData.count) bytes. Expected 1024")
        }
        return frameData
    }
}


// MARK: - Glucose history
extension PumpOpsSession {
    private func logGlucoseHistory(pageData: Data, pageNum: Int) {
        var idx = 0
        let chunkSize = 256
        while idx < pageData.count {
            let top = min(idx + chunkSize, pageData.count)
            let range = Range(uncheckedBounds: (lower: idx, upper: top))
            // TODO: Convert logging
            NSLog(String(format: "GlucosePage %02d - (bytes %03d-%03d): ", pageNum, idx, top-1) + pageData.subdata(in: range).hexadecimalString)
            idx = top
        }
    }
    
    /// Fetches glucose history entries which occurred on or after the specified date.
    ///
    /// History timestamps are reconciled with UTC based on the `timeZone` property of PumpState, as well as recorded clock change events.
    ///
    /// - Parameter startDate: The earliest date of events to retrieve
    /// - Returns: An array of fetched history entries, in ascending order of insertion
    /// - Throws: 
    public func getGlucoseHistoryEvents(since startDate: Date) throws -> [TimestampedGlucoseEvent] {
        try wakeup()
        
        var events = [TimestampedGlucoseEvent]()
        
        let currentGlucosePage: ReadCurrentGlucosePageMessageBody = try session.getResponse(to: PumpMessage(settings: settings, type: .readCurrentGlucosePage), responseType: .readCurrentGlucosePage)
        let startPage = Int(currentGlucosePage.pageNum)
        //max lookback of 15 pages or when page is 0
        let endPage = max(startPage - 15, 0)
        
        pages: for pageNum in stride(from: startPage, to: endPage - 1, by: -1) {
            // TODO: Convert logging
            NSLog("Fetching page %d", pageNum)
            var pageData: Data
            var page: GlucosePage
            
            do {
                pageData = try getGlucosePage(UInt32(pageNum))
                // logGlucoseHistory(pageData: pageData, pageNum: pageNum)
                page = try GlucosePage(pageData: pageData)
                
                if page.needsTimestamp && pageNum == startPage {
                    // TODO: Convert logging
                    NSLog(String(format: "GlucosePage %02d needs a new sensor timestamp, writing...", pageNum))
                    let _ = try writeGlucoseHistoryTimestamp()
                    
                    //fetch page again with new sensor timestamp
                    pageData = try getGlucosePage(UInt32(pageNum))
                    logGlucoseHistory(pageData: pageData, pageNum: pageNum)
                    page = try GlucosePage(pageData: pageData)
                }
            } catch PumpOpsError.pumpError {
                break pages
            }
            
            for event in page.events.reversed() {
                var timestamp = event.timestamp
                timestamp.timeZone = pump.timeZone
                
                if event is UnknownGlucoseEvent {
                    continue pages
                }
                
                if let date = timestamp.date {
                    if date < startDate && event is SensorTimestampGlucoseEvent {
                        // TODO: Convert logging
                        NSLog("Found reference event at (%@) to be before startDate(%@)", date as NSDate, startDate as NSDate)
                        break pages
                    } else {
                        events.insert(TimestampedGlucoseEvent(glucoseEvent: event, date: date), at: 0)
                    }
                }
            }
        }
        return events
    }

    private func getGlucosePage(_ pageNum: UInt32) throws -> Data {
        var frameData = Data()
        
        let msg = PumpMessage(settings: settings, type: .getGlucosePage, body: GetGlucosePageMessageBody(pageNum: pageNum))

        var curResp: GetGlucosePageMessageBody = try runCommandWithArguments(msg, responseType: .getGlucosePage)
        
        var expectedFrameNum = 1
        
        while(expectedFrameNum == curResp.frameNumber) {
            frameData.append(curResp.frame)
            expectedFrameNum += 1
            let msg = PumpMessage(settings: settings, type: .pumpAck)
            if !curResp.lastFrame {
                curResp = try session.getResponse(to: msg, responseType: .getGlucosePage)
            } else {
                try session.send(msg)
                break
            }
        }
        
        guard frameData.count == 1024 else {
            throw PumpOpsError.rfCommsFailure("Short glucose history page: \(frameData.count) bytes. Expected 1024")
        }
        return frameData
    }
    
    public func writeGlucoseHistoryTimestamp() throws -> Void {
        try wakeup()

        let shortWriteTimestamp = PumpMessage(settings: settings, type: .writeGlucoseHistoryTimestamp)
        let _: PumpAckMessageBody = try session.getResponse(to: shortWriteTimestamp, timeout: .seconds(12))
    }
}
