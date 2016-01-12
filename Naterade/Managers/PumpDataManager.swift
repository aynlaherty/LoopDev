//
//  PumpDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import HealthKit
import MinimedKit
import RileyLinkKit
import WatchConnectivity
import xDripG5

enum State<T> {
    case NeedsConfiguration
    case Ready(T)
}

class ConnectDelegate: NSObject, WCSessionDelegate {

}

class PumpDataManager: TransmitterDelegate {
    static let GlucoseUpdatedNotification = "com.loudnate.Naterade.notification.GlucoseUpdated"
    static let PumpStatusUpdatedNotification = "com.loudnate.Naterade.notification.PumpStatusUpdated"

    // MARK: - Observed state

    lazy var logger = DiagnosticLogger()

    var rileyLinkManager: RileyLinkManager? {
        switch rileyLinkState {
        case .Ready(let manager):
            return manager
        case .NeedsConfiguration:
            return nil
        }
    }

    var transmitter: Transmitter? {
        switch transmitterState {
        case .Ready(let transmitter):
            return transmitter
        case .NeedsConfiguration:
            return nil
        }
    }

    // MARK: - RileyLink

    var rileyLinkManagerObserver: AnyObject? {
        willSet {
            if let observer = rileyLinkManagerObserver {
                NSNotificationCenter.defaultCenter().removeObserver(observer)
            }
        }
    }

    var rileyLinkDeviceObserver: AnyObject? {
        willSet {
            if let observer = rileyLinkDeviceObserver {
                NSNotificationCenter.defaultCenter().removeObserver(observer)
            }
        }
    }

    func receivedRileyLinkManagerNotification(note: NSNotification) {
        NSNotificationCenter.defaultCenter().postNotificationName(note.name, object: self, userInfo: note.userInfo)
    }

    func receivedRileyLinkPacketNotification(note: NSNotification) {
        if let
            device = note.object as? RileyLinkDevice,
            packet = note.userInfo?[RileyLinkDevicePacketKey] as? MinimedPacket where packet.valid == true,
            let data = packet.data,
            message = PumpMessage(rxData: data)
        {
            switch message.packetType {
            case .MySentry:
                switch message.messageBody {
                case let body as MySentryPumpStatusMessageBody:
                    updatePumpStatus(body, fromDevice: device)
                case is MySentryAlertMessageBody:
                    break
                    // TODO: de-dupe
//                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryAlert")
                case is MySentryAlertClearedMessageBody:
                    break
                    // TODO: de-dupe
//                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryAlert")
                case let body as UnknownMessageBody:
                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryOther")
                default:
                    break
                }
            default:
                break
            }
        }
    }

    func connectToRileyLink(device: RileyLinkDevice) {
        connectedPeripheralIDs.insert(device.peripheral.identifier.UUIDString)

        rileyLinkManager?.connectDevice(device)
    }

    func disconnectFromRileyLink(device: RileyLinkDevice) {
        connectedPeripheralIDs.remove(device.peripheral.identifier.UUIDString)

        rileyLinkManager?.disconnectDevice(device)
    }

    private func updatePumpStatus(status: MySentryPumpStatusMessageBody, fromDevice device: RileyLinkDevice) {
        if status != latestPumpStatus {
            latestPumpStatus = status

//            logger?.addMessage(status.dictionaryRepresentation, toCollection: "sentryMessage")
        }
    }

    // MARK: - Transmitter

    private func updateGlucose(glucose: GlucoseRxMessage) {
        if glucose != latestGlucose {
            latestGlucose = glucose
            updateWatch()
        }
    }

    // MARK: TransmitterDelegate

    func transmitter(transmitter: Transmitter, didError error: ErrorType) {
        logger?.addMessage([
            "error": "\(error)",
            "collectedAt": NSDateFormatter.ISO8601DateFormatter().stringFromDate(NSDate())
            ], toCollection: "g5"
        )

        NSLog("%s, %@", __FUNCTION__, "\(error)")
    }

    func transmitter(transmitter: Transmitter, didReadGlucose glucose: GlucoseRxMessage) {
        transmitterStartTime = transmitter.startTimeInterval
        updateGlucose(glucose)
    }

    // MARK: - Managed state

    var transmitterStartTime: NSTimeInterval? = NSUserDefaults.standardUserDefaults().transmitterStartTime {
        didSet {
            if oldValue != transmitterStartTime {
                NSUserDefaults.standardUserDefaults().transmitterStartTime = transmitterStartTime
            }
        }
    }

    var latestGlucose: GlucoseRxMessage? {
        didSet {
            if let complicationGlucose = latestComplicationGlucose, let glucose = latestGlucose {
                complicationShouldUpdate = Int(glucose.timestamp) - Int(complicationGlucose.timestamp) >= 30 * 60 || abs(Int(glucose.glucose) - Int(complicationGlucose.glucose)) >= 20
            } else {
                complicationShouldUpdate = true
            }

            NSNotificationCenter.defaultCenter().postNotificationName(self.dynamicType.GlucoseUpdatedNotification, object: self)
        }
    }

    var latestComplicationGlucose: GlucoseRxMessage?

    var complicationShouldUpdate = false

    var latestPumpStatus: MySentryPumpStatusMessageBody? {
        didSet {
            NSNotificationCenter.defaultCenter().postNotificationName(self.dynamicType.PumpStatusUpdatedNotification, object: self)
        }
    }

    var transmitterState: State<Transmitter> = .NeedsConfiguration {
        didSet {
            switch transmitterState {
            case .Ready(let transmitter):
                transmitter.delegate = self
            case .NeedsConfiguration:
                break
            }
        }
    }

    var rileyLinkState: State<RileyLinkManager> = .NeedsConfiguration {
        willSet {
            switch newValue {
            case .Ready(let manager):
                rileyLinkManagerObserver = NSNotificationCenter.defaultCenter().addObserverForName(nil, object: manager, queue: nil) { [weak self = self] (note) -> Void in
                    self?.receivedRileyLinkManagerNotification(note)
                }

                rileyLinkDeviceObserver = NSNotificationCenter.defaultCenter().addObserverForName(RileyLinkDeviceDidReceivePacketNotification, object: nil, queue: nil, usingBlock: { [weak self = self] (note) -> Void in
                    self?.receivedRileyLinkPacketNotification(note)
                })

            case .NeedsConfiguration:
                rileyLinkManagerObserver = nil
                rileyLinkDeviceObserver = nil
            }
        }
    }

    var connectedPeripheralIDs: Set<String> {
        didSet {
            NSUserDefaults.standardUserDefaults().connectedPeripheralIDs = Array(connectedPeripheralIDs)
        }
    }

    var pumpID: String? {
        didSet {
            if pumpID?.characters.count != 6 {
                pumpID = nil
            }

            switch (rileyLinkState, pumpID) {
            case (_, let pumpID?):
                rileyLinkState = .Ready(RileyLinkManager(pumpID: pumpID, autoconnectIDs: connectedPeripheralIDs))
            case (.NeedsConfiguration, .None):
                break
            case (.Ready, .None):
                rileyLinkState = .NeedsConfiguration
            }

            NSUserDefaults.standardUserDefaults().pumpID = pumpID
        }
    }

    var transmitterID: String? {
        didSet {
            if transmitterID?.characters.count != 6 {
                transmitterID = nil
            }

            switch (transmitterState, transmitterID) {
            case (.NeedsConfiguration, let transmitterID?):
                transmitterState = .Ready(Transmitter(
                    ID: transmitterID,
                    startTimeInterval: NSUserDefaults.standardUserDefaults().transmitterStartTime,
                    passiveModeEnabled: true
                ))
            case (.Ready, .None):
                transmitterState = .NeedsConfiguration
            case (.Ready(let transmitter), let transmitterID?):
                transmitter.ID = transmitterID
                transmitter.startTimeInterval = nil
            case (.NeedsConfiguration, .None):
                break
            }

            NSUserDefaults.standardUserDefaults().transmitterID = transmitterID
        }
    }

    // MARK: - CarbKit

    let carbStore = CarbStore()

    // MARK: - HealthKit

    private lazy var glucoseQuantityType = HKSampleType.quantityTypeForIdentifier(HKQuantityTypeIdentifierBloodGlucose)!

    lazy var healthStore: HKHealthStore? = {
        if HKHealthStore.isHealthDataAvailable() {
            let store = HKHealthStore()
            let shareTypes = Set(arrayLiteral: self.glucoseQuantityType)

            store.requestAuthorizationToShareTypes(shareTypes, readTypes: nil, completion: { (completed, error) -> Void in
                if let error = error {
                    NSLog("Failed to gain HealthKit authorization: %@", error)
                }
            })

            return store
        } else {
            NSLog("Health data is not available on this device")
            return nil
        }
    }()

    // MARK: - WatchKit

    private lazy var watchSessionDelegate = ConnectDelegate()

    private lazy var watchSession: WCSession? = {
        if WCSession.isSupported() {
            let session = WCSession.defaultSession()
            session.delegate = self.watchSessionDelegate
            session.activateSession()

            return session
        } else {
            return nil
        }
    }()

    private func updateWatch() {
        if let session = watchSession where session.paired && session.watchAppInstalled {
            let userInfo = WatchContext(pumpStatus: latestPumpStatus, glucose: latestGlucose, transmitterStartTime: transmitterStartTime).rawValue

            if session.complicationEnabled && complicationShouldUpdate, let glucose = latestGlucose {
                session.transferCurrentComplicationUserInfo(userInfo)
                latestComplicationGlucose = glucose
                complicationShouldUpdate = false
            } else {
                do {
                    try session.updateApplicationContext(userInfo)
                } catch let error {
                    NSLog("WCSession error: \(error)")
                }
            }
        }
    }

    // MARK: - Initialization

    static let sharedManager = PumpDataManager()

    init() {
        connectedPeripheralIDs = Set(NSUserDefaults.standardUserDefaults().connectedPeripheralIDs)
    }

    deinit {
        rileyLinkManagerObserver = nil
        rileyLinkDeviceObserver = nil
    }
}


extension WatchContext {
    convenience init(pumpStatus: MySentryPumpStatusMessageBody?, glucose: GlucoseRxMessage?, transmitterStartTime: NSTimeInterval?) {
        self.init()

        if let glucose = glucose, transmitterStartTime = transmitterStartTime where glucose.state > 5 {
            glucoseValue = Int(glucose.glucose)
            glucoseTrend = Int(glucose.trend)
            glucoseDate = NSDate(timeIntervalSince1970: transmitterStartTime).dateByAddingTimeInterval(NSTimeInterval(glucose.timestamp))
        }

        if let status = pumpStatus {
            IOB = status.iob
            reservoir = status.reservoirRemainingUnits
            pumpDate = status.pumpDate
        }
    }
}
