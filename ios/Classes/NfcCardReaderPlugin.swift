import Flutter
import UIKit
import CoreNFC

public class NfcCardReaderPlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    private var nfcSession: NFCTagReaderSession?
    private var isReading = false
    private var diagnosticLog: [String] = []
    private var retryCount = 0
    private static let maxRetries = 1

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NfcCardReaderPlugin()

        let methodChannel = FlutterMethodChannel(name: "nfc_card_reader", binaryMessenger: registrar.messenger())
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(name: "nfc_card_reader/events", binaryMessenger: registrar.messenger())
        instance.eventChannel = eventChannel
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isNfcAvailable":
            result(NFCTagReaderSession.readingAvailable)
        case "isNfcEnabled":
            result(NFCTagReaderSession.readingAvailable)
        case "startReading":
            startReading()
            result(nil)
        case "stopReading":
            stopReading()
            result(nil)
        case "openNfcSettings":
            openNfcSettings()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startReading() {
        guard NFCTagReaderSession.readingAvailable else {
            sendError("NFC is not available on this device")
            return
        }

        if nfcSession != nil { return }

        diagnosticLog = []
        retryCount = 0
        nfcSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        nfcSession?.alertMessage = "Hold your card near the iPhone"
        nfcSession?.begin()
        isReading = true
    }

    private func stopReading() {
        let session = nfcSession
        nfcSession = nil
        isReading = false
        session?.invalidate()
    }

    private func openNfcSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
    }

    private func sendCardData(_ cardData: [String: Any?]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": "card", "data": cardData] as [String: Any])
        }
    }

    private func sendError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": "error", "message": message] as [String: Any])
        }
    }

    private func diag(_ message: String) {
        NSLog("[NfcCardReader] %@", message)
        diagnosticLog.append(message)
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": "debug", "message": "[iOS-NFC] \(message)"] as [String: Any])
        }
    }

    private func toHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private func failWithDiagnostics(session: NFCTagReaderSession) {
        let summary = diagnosticLog.suffix(20).joined(separator: "\n")
        session.invalidate(errorMessage: "Could not read card data")
        sendError("Could not read card. Diagnostics:\n\(summary)")
    }
}

// MARK: - FlutterStreamHandler
extension NfcCardReaderPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - NFCTagReaderSessionDelegate
extension NfcCardReaderPlugin: NFCTagReaderSessionDelegate {
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        diag("Session active")
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        diag("Session ended: \(error.localizedDescription)")
        guard session === nfcSession || nfcSession == nil else { return }
        if let nfcError = error as? NFCReaderError {
            if nfcError.code != .readerSessionInvalidationErrorFirstNDEFTagRead &&
               nfcError.code != .readerSessionInvalidationErrorUserCanceled {
                sendError(error.localizedDescription)
            }
        }
        isReading = false
        nfcSession = nil
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard session === nfcSession else { return }

        // Look for MiFare tag FIRST (preferred — no AID restriction)
        // Then ISO7816 as fallback
        var selectedTag: NFCTag?
        var miFareTag: NFCMiFareTag?
        var iso7816Tag: NFCISO7816Tag?

        for tag in tags {
            switch tag {
            case .miFare(let t):
                if miFareTag == nil {
                    miFareTag = t
                    selectedTag = tag
                    diag("Found MiFare tag: family=\(t.mifareFamily.rawValue) ID=\(toHex(t.identifier))")
                }
            case .iso7816(let t):
                if iso7816Tag == nil {
                    iso7816Tag = t
                    if selectedTag == nil { selectedTag = tag }
                    diag("Found ISO7816 tag: AID=\(t.initialSelectedAID) ID=\(toHex(t.identifier))")
                    if let hb = t.historicalBytes { diag("HistoricalBytes=\(toHex(hb))") }
                    if let ad = t.applicationData { diag("ApplicationData=\(toHex(ad))") }
                }
            default:
                diag("Found other tag type")
            }
        }

        // Prefer MiFare (works without AID pre-selection)
        if let _ = miFareTag, let tag = tags.first(where: {
            if case .miFare = $0 { return true }; return false
        }) {
            selectedTag = tag
            diag("Using MiFare tag (no AID restriction)")
        } else if let iTag = iso7816Tag, !iTag.initialSelectedAID.isEmpty {
            selectedTag = tags.first(where: {
                if case .iso7816 = $0 { return true }; return false
            })
            diag("Using ISO7816 tag with AID=\(iTag.initialSelectedAID)")
        } else if iso7816Tag != nil {
            // ISO7816 with EMPTY AID — no AID matched during detection
            diag("ISO7816 tag has EMPTY AID — card's AID not in Info.plist")
            diag("CoreNFC cannot send APDUs without a matched AID")

            if retryCount < NfcCardReaderPlugin.maxRetries {
                retryCount += 1
                diag("Restarting polling (retry \(retryCount))...")
                session.restartPolling()
                return
            }

            diag("Card AID not recognized. Run on Android to discover the AID.")
            session.invalidate(errorMessage: "Card type not supported on iOS")
            sendError("Card AID not recognized by iOS.\n\nTo fix: run the app on Android with this card. Check the debug log for 'SUCCESS with AID: XXXXXX'. Add that AID hex string to Info.plist's com.apple.developer.nfc.readersession.iso7816.select-identifiers list.")
            return
        }

        guard let tagToConnect = selectedTag else {
            session.invalidate(errorMessage: "No compatible tag found")
            return
        }

        session.connect(to: tagToConnect) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.diag("Connect error: \(error.localizedDescription)")
                session.invalidate(errorMessage: "Connection failed")
                return
            }

            session.alertMessage = "Reading card..."

            switch tagToConnect {
            case .miFare(let tag):
                self.readViaMiFare(tag: tag, session: session)
            case .iso7816(let tag):
                self.readViaISO7816(tag: tag, session: session)
            default:
                session.invalidate(errorMessage: "Unsupported tag")
            }
        }
    }
}

// MARK: - APDU Helpers
extension NfcCardReaderPlugin {

    private func sendISO(_ tag: NFCISO7816Tag, cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8,
                         data: Data?, le: Int = 256,
                         completion: @escaping (Data, UInt8, UInt8) -> Void) {
        let apdu = NFCISO7816APDU(
            instructionClass: cla, instructionCode: ins,
            p1Parameter: p1, p2Parameter: p2,
            data: data ?? Data(), expectedResponseLength: le
        )
        tag.sendCommand(apdu: apdu) { [weak self] resp, sw1, sw2, error in
            if let error = error {
                self?.diag("APDU \(String(format:"%02X%02X",cla,ins)) ERR: \(error.localizedDescription)")
                completion(Data(), 0, 0)
                return
            }
            self?.diag("APDU \(String(format:"%02X%02X",cla,ins)) SW=\(String(format:"%02X%02X",sw1,sw2)) len=\(resp.count)")
            completion(resp, sw1, sw2)
        }
    }

    private func sendMiFare(_ tag: NFCMiFareTag, cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8,
                            data: Data?, le: Int = 256,
                            completion: @escaping (Data, UInt8, UInt8) -> Void) {
        let apdu = NFCISO7816APDU(
            instructionClass: cla, instructionCode: ins,
            p1Parameter: p1, p2Parameter: p2,
            data: data ?? Data(), expectedResponseLength: le
        )
        tag.sendMiFareISO7816Command(apdu) { [weak self] resp, sw1, sw2, error in
            if let error = error {
                self?.diag("MF-APDU \(String(format:"%02X%02X",cla,ins)) ERR: \(error.localizedDescription)")
                completion(Data(), 0, 0)
                return
            }
            self?.diag("MF-APDU \(String(format:"%02X%02X",cla,ins)) SW=\(String(format:"%02X%02X",sw1,sw2)) len=\(resp.count)")
            completion(resp, sw1, sw2)
        }
    }

    private func ok(_ sw1: UInt8, _ sw2: UInt8) -> Bool { sw1 == 0x90 && sw2 == 0x00 }
}

// MARK: - ISO7816 Reading (when AID was pre-selected)
extension NfcCardReaderPlugin {

    private static let knownAIDs: [Data] = [
        Data([0xA0, 0x86, 0x00, 0x01, 0x00, 0x00, 0x01]), // UzCard (A0860001000001)
        Data([0xA0, 0x00, 0x00, 0x00, 0x03, 0x10, 0x10]), // Visa
        Data([0xA0, 0x00, 0x00, 0x00, 0x04, 0x10, 0x10]), // Mastercard
        Data([0xA0, 0x00, 0x00, 0x00, 0x03, 0x20, 0x10]), // Visa Debit
        Data([0xA0, 0x00, 0x00, 0x00, 0x03, 0x20, 0x20]), // Visa Electron
        Data([0xA0, 0x00, 0x00, 0x00, 0x04, 0x30, 0x60]), // Maestro
        Data([0xA0, 0x00, 0x00, 0x00, 0x25, 0x01]),       // Amex
        Data([0xA0, 0x00, 0x00, 0x00, 0x25, 0x01, 0x04]), // Amex full
        Data([0xA0, 0x00, 0x00, 0x01, 0x52, 0x30, 0x10]), // Discover
        Data([0xA0, 0x00, 0x00, 0x03, 0x33, 0x01, 0x01]), // UnionPay
        Data([0xA0, 0x00, 0x00, 0x00, 0x65, 0x10, 0x10]), // JCB
        Data([0xA0, 0x00, 0x00, 0x06, 0x58, 0x10, 0x10]), // MIR
        Data([0xA0, 0x00, 0x00, 0x06, 0x58, 0x10, 0x11]), // MIR Debit
        Data([0xA0, 0x00, 0x00, 0x05, 0x24, 0x10, 0x10]), // RuPay
        Data([0xD8, 0x60, 0x00, 0x00, 0x02]),             // UzCard
        Data([0xD8, 0x60, 0x00, 0x00, 0x02, 0x01, 0x01]), // UzCard full
        Data([0xD8, 0x60, 0x00, 0x00, 0x03]),             // Humo
        Data([0xD8, 0x60, 0x00, 0x00, 0x03, 0x01, 0x01]), // Humo full
        Data([0xD8, 0x60, 0x00, 0x00, 0x01]),             // Local 1
        Data([0xD8, 0x60, 0x00, 0x00, 0x01, 0x01, 0x01]), // Local 1 full
        Data([0xA0, 0x00, 0x00, 0x04, 0x32, 0x01, 0x01]), // CB Debit
        Data([0xA0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]), // MC range
    ]

    private func readViaISO7816(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        let initialAID = tag.initialSelectedAID
        diag("readViaISO7816: initialAID=\(initialAID)")

        if initialAID == "325041592E5359532E4444463031" {
            // PPSE was auto-selected — discover the card's real AID
            diag("PPSE auto-selected, discovering real AID")
            strategy2_PPSE_ISO(tag: tag, session: session)
            return
        }

        // Payment AID was auto-selected — re-SELECT to get FCI/PDOL, then GPO
        if !initialAID.isEmpty, let aidData = hexToData(initialAID) {
            diag("Re-selecting \(initialAID) to get PDOL")
            selectAndRead_ISO(aid: aidData, tag: tag) { [weak self] cardData in
                guard let self = self else { return }
                if let cardData = cardData {
                    self.finish(cardData, session: session)
                    return
                }
                // AID failed — skip PPSE (it can break the session), go to known AIDs
                self.diag("Re-select flow failed, trying known AIDs")
                self.strategy3_knownAIDs_ISO(tag: tag, session: session, idx: 0)
            }
            return
        }

        strategy2_PPSE_ISO(tag: tag, session: session)
    }

    private func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = Array(hex)
        var i = 0
        while i + 1 < chars.count {
            guard let b1 = hexNibble(chars[i]), let b2 = hexNibble(chars[i+1]) else { return nil }
            data.append((b1 << 4) | b2)
            i += 2
        }
        return data.isEmpty ? nil : data
    }

    private func hexNibble(_ c: Character) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(c.asciiValue! - Character("a").asciiValue! + 10)
        case "A"..."F": return UInt8(c.asciiValue! - Character("A").asciiValue! + 10)
        default: return nil
        }
    }

    private func tryDirectGPO_ISO(tag: NFCISO7816Tag, completion: @escaping ([String: Any?]?) -> Void) {
        // Try empty PDOL first (Mastercard etc)
        let emptyGPO = Data([0x83, 0x00])
        sendISO(tag, cla: 0x80, ins: 0xA8, p1: 0x00, p2: 0x00, data: emptyGPO) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            if self.ok(sw1, sw2) && data.count > 0 {
                if let cd = self.extractCardData(from: data), cd["cardNumber"] != nil {
                    completion(cd); return
                }
                let afls = self.extractAFL(from: data)
                self.readRecords_ISO(tag: tag, afls: afls, idx: 0, acc: [:], completion: completion)
                return
            }
            // Try standard Visa PDOL
            let stdPDOL = self.standardPDOLData()
            var gpo2 = Data([0x83, UInt8(stdPDOL.count)])
            gpo2.append(stdPDOL)
            self.sendISO(tag, cla: 0x80, ins: 0xA8, p1: 0x00, p2: 0x00, data: gpo2) { d2, s1, s2 in
                if self.ok(s1, s2) && d2.count > 0 {
                    if let cd = self.extractCardData(from: d2), cd["cardNumber"] != nil {
                        completion(cd); return
                    }
                    let afls = self.extractAFL(from: d2)
                    self.readRecords_ISO(tag: tag, afls: afls, idx: 0, acc: [:], completion: completion)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func strategy2_PPSE_ISO(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        diag("Strategy 2: PPSE")
        let ppse = "2PAY.SYS.DDF01".data(using: .ascii)!
        sendISO(tag, cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00, data: ppse) { [weak self] data, sw1, sw2 in
            guard let self = self else { return }
            if self.ok(sw1, sw2) && data.count > 0 {
                let aids = self.extractAllAIDs(from: data)
                self.diag("PPSE found \(aids.count) AID(s)")
                if !aids.isEmpty {
                    self.tryAIDs_ISO(aids: aids, tag: tag, idx: 0) { cd in
                        if let cd = cd { self.finish(cd, session: session) }
                        else { self.strategy3_knownAIDs_ISO(tag: tag, session: session, idx: 0) }
                    }
                    return
                }
            }
            self.diag("PPSE failed")
            self.strategy3_knownAIDs_ISO(tag: tag, session: session, idx: 0)
        }
    }

    private func strategy3_knownAIDs_ISO(tag: NFCISO7816Tag, session: NFCTagReaderSession, idx: Int) {
        guard idx < NfcCardReaderPlugin.knownAIDs.count else {
            diag("All AIDs exhausted")
            failWithDiagnostics(session: session)
            return
        }
        let aid = NfcCardReaderPlugin.knownAIDs[idx]
        selectAndRead_ISO(aid: aid, tag: tag) { [weak self] cd in
            if let cd = cd { self?.finish(cd, session: session) }
            else { self?.strategy3_knownAIDs_ISO(tag: tag, session: session, idx: idx + 1) }
        }
    }

    private func tryAIDs_ISO(aids: [Data], tag: NFCISO7816Tag, idx: Int, completion: @escaping ([String: Any?]?) -> Void) {
        guard idx < aids.count else { completion(nil); return }
        selectAndRead_ISO(aid: aids[idx], tag: tag) { [weak self] cd in
            if let cd = cd { completion(cd) }
            else { self?.tryAIDs_ISO(aids: aids, tag: tag, idx: idx + 1, completion: completion) }
        }
    }

    private func selectAndRead_ISO(aid: Data, tag: NFCISO7816Tag, completion: @escaping ([String: Any?]?) -> Void) {
        sendISO(tag, cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00, data: aid) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            guard self.ok(sw1, sw2) else { completion(nil); return }
            self.diag("SELECT OK \(self.toHex(aid))")
            if let cd = self.extractCardData(from: data), cd["cardNumber"] != nil { completion(cd); return }
            let pdol = self.extractPDOL(from: data)
            self.doGPOAndRead_ISO(tag: tag, pdol: pdol, completion: completion)
        }
    }

    private func doGPOAndRead_ISO(tag: NFCISO7816Tag, pdol: Data?, completion: @escaping ([String: Any?]?) -> Void) {
        var pdolData = Data()
        if let p = pdol, !p.isEmpty { pdolData = buildPDOLData(p) }
        var cmd = Data([0x83, UInt8(pdolData.count)])
        cmd.append(pdolData)

        sendISO(tag, cla: 0x80, ins: 0xA8, p1: 0x00, p2: 0x00, data: cmd) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            if self.ok(sw1, sw2) && data.count > 0 {
                self.diag("GPO OK (\(data.count)b)")
                if let cd = self.extractCardData(from: data), cd["cardNumber"] != nil { completion(cd); return }
                let afls = self.extractAFL(from: data)
                self.readRecords_ISO(tag: tag, afls: afls, idx: 0, acc: [:], completion: completion)
            } else {
                self.diag("GPO fail, brute-force records")
                var fb: [(sfi:Int,rec:Int)] = []
                for s in 1...3 { for r in 1...5 { fb.append((sfi:s,rec:r)) } }
                self.readRecords_ISO(tag: tag, afls: fb, idx: 0, acc: [:], completion: completion)
            }
        }
    }

    private func readRecords_ISO(tag: NFCISO7816Tag, afls: [(sfi:Int,rec:Int)], idx: Int, acc: [String:Any?], completion: @escaping ([String:Any?]?) -> Void) {
        guard idx < afls.count else {
            completion(acc["cardNumber"] != nil && acc["expirationDate"] != nil ? acc : nil)
            return
        }
        let a = afls[idx]; let p2 = UInt8((a.sfi << 3) | 0x04)
        sendISO(tag, cla: 0x00, ins: 0xB2, p1: UInt8(a.rec), p2: p2, data: nil) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            var cur = acc
            if self.ok(sw1, sw2) && data.count > 0, let cd = self.extractCardData(from: data) {
                if cur["cardNumber"] == nil, let v = cd["cardNumber"] { cur["cardNumber"] = v }
                if cur["expirationDate"] == nil, let v = cd["expirationDate"] { cur["expirationDate"] = v }
                if cur["cardholderName"] == nil, let v = cd["cardholderName"] { cur["cardholderName"] = v }
                if cur["cardNumber"] != nil && cur["expirationDate"] != nil { completion(cur); return }
            }
            self.readRecords_ISO(tag: tag, afls: afls, idx: idx + 1, acc: cur, completion: completion)
        }
    }
}

// MARK: - MiFare Reading (NO AID restriction — can read any card)
extension NfcCardReaderPlugin {

    private func readViaMiFare(tag: NFCMiFareTag, session: NFCTagReaderSession) {
        diag("readViaMiFare: family=\(tag.mifareFamily.rawValue)")

        // MiFare tags don't have AID pre-selection restrictions!
        // Try PPSE first to discover the card's AID
        diag("MiFare: trying PPSE")
        let ppse = "2PAY.SYS.DDF01".data(using: .ascii)!
        sendMiFare(tag, cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00, data: ppse) { [weak self] data, sw1, sw2 in
            guard let self = self else { return }
            if self.ok(sw1, sw2) && data.count > 0 {
                let aids = self.extractAllAIDs(from: data)
                self.diag("MiFare PPSE found \(aids.count) AID(s)")
                for aid in aids { self.diag("  AID: \(self.toHex(aid))") }

                if !aids.isEmpty {
                    self.tryAIDs_MF(aids: aids, tag: tag, idx: 0) { cd in
                        if let cd = cd { self.finish(cd, session: session) }
                        else { self.knownAIDs_MF(tag: tag, session: session, idx: 0) }
                    }
                    return
                }
            }
            self.diag("MiFare PPSE failed")
            self.knownAIDs_MF(tag: tag, session: session, idx: 0)
        }
    }

    private func knownAIDs_MF(tag: NFCMiFareTag, session: NFCTagReaderSession, idx: Int) {
        guard idx < NfcCardReaderPlugin.knownAIDs.count else {
            diag("MiFare: all AIDs exhausted")
            failWithDiagnostics(session: session)
            return
        }
        let aid = NfcCardReaderPlugin.knownAIDs[idx]
        selectAndRead_MF(aid: aid, tag: tag) { [weak self] cd in
            if let cd = cd { self?.finish(cd, session: session) }
            else { self?.knownAIDs_MF(tag: tag, session: session, idx: idx + 1) }
        }
    }

    private func tryAIDs_MF(aids: [Data], tag: NFCMiFareTag, idx: Int, completion: @escaping ([String:Any?]?) -> Void) {
        guard idx < aids.count else { completion(nil); return }
        selectAndRead_MF(aid: aids[idx], tag: tag) { [weak self] cd in
            if let cd = cd { completion(cd) }
            else { self?.tryAIDs_MF(aids: aids, tag: tag, idx: idx + 1, completion: completion) }
        }
    }

    private func selectAndRead_MF(aid: Data, tag: NFCMiFareTag, completion: @escaping ([String:Any?]?) -> Void) {
        sendMiFare(tag, cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00, data: aid) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            guard self.ok(sw1, sw2) else { completion(nil); return }
            self.diag("MF SELECT OK \(self.toHex(aid))")
            if let cd = self.extractCardData(from: data), cd["cardNumber"] != nil { completion(cd); return }
            let pdol = self.extractPDOL(from: data)
            self.doGPOAndRead_MF(tag: tag, pdol: pdol, completion: completion)
        }
    }

    private func doGPOAndRead_MF(tag: NFCMiFareTag, pdol: Data?, completion: @escaping ([String:Any?]?) -> Void) {
        var pdolData = Data()
        if let p = pdol, !p.isEmpty { pdolData = buildPDOLData(p) }
        var cmd = Data([0x83, UInt8(pdolData.count)])
        cmd.append(pdolData)

        sendMiFare(tag, cla: 0x80, ins: 0xA8, p1: 0x00, p2: 0x00, data: cmd) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            if self.ok(sw1, sw2) && data.count > 0 {
                self.diag("MF GPO OK (\(data.count)b)")
                if let cd = self.extractCardData(from: data), cd["cardNumber"] != nil { completion(cd); return }
                let afls = self.extractAFL(from: data)
                self.readRecords_MF(tag: tag, afls: afls, idx: 0, acc: [:], completion: completion)
            } else {
                self.diag("MF GPO fail, brute-force")
                var fb: [(sfi:Int,rec:Int)] = []
                for s in 1...3 { for r in 1...5 { fb.append((sfi:s,rec:r)) } }
                self.readRecords_MF(tag: tag, afls: fb, idx: 0, acc: [:], completion: completion)
            }
        }
    }

    private func readRecords_MF(tag: NFCMiFareTag, afls: [(sfi:Int,rec:Int)], idx: Int, acc: [String:Any?], completion: @escaping ([String:Any?]?) -> Void) {
        guard idx < afls.count else {
            completion(acc["cardNumber"] != nil && acc["expirationDate"] != nil ? acc : nil)
            return
        }
        let a = afls[idx]; let p2 = UInt8((a.sfi << 3) | 0x04)
        sendMiFare(tag, cla: 0x00, ins: 0xB2, p1: UInt8(a.rec), p2: p2, data: nil) { [weak self] data, sw1, sw2 in
            guard let self = self else { completion(nil); return }
            var cur = acc
            if self.ok(sw1, sw2) && data.count > 0, let cd = self.extractCardData(from: data) {
                if cur["cardNumber"] == nil, let v = cd["cardNumber"] { cur["cardNumber"] = v }
                if cur["expirationDate"] == nil, let v = cd["expirationDate"] { cur["expirationDate"] = v }
                if cur["cardholderName"] == nil, let v = cd["cardholderName"] { cur["cardholderName"] = v }
                if cur["cardNumber"] != nil && cur["expirationDate"] != nil { completion(cur); return }
            }
            self.readRecords_MF(tag: tag, afls: afls, idx: idx + 1, acc: cur, completion: completion)
        }
    }
}

// MARK: - Finish
extension NfcCardReaderPlugin {
    private func finish(_ cardData: [String: Any?], session: NFCTagReaderSession) {
        diag("SUCCESS: \(cardData)")
        session.alertMessage = "Card read successfully!"
        session.invalidate()
        sendCardData(cardData)
    }
}

// MARK: - PDOL
extension NfcCardReaderPlugin {

    private func standardPDOLData() -> Data {
        var d = Data(count: 28)
        d[0] = 0x27; d[1] = 0x80 // TTQ
        d[9] = 0x01 // Amount
        d[16] = 0x08; d[17] = 0x40 // Country UZ
        d[18] = 0x08; d[19] = 0x40 // Currency UZS
        let c = Calendar.current; let now = Date()
        let y = c.component(.year, from: now) % 100
        let m = c.component(.month, from: now)
        let dy = c.component(.day, from: now)
        d[20] = UInt8((y/10)<<4|(y%10)); d[21] = UInt8((m/10)<<4|(m%10)); d[22] = UInt8((dy/10)<<4|(dy%10))
        d[23] = 0x00 // Transaction type
        let r = UInt32.random(in: 0...UInt32.max)
        d[24] = UInt8((r>>24)&0xFF); d[25] = UInt8((r>>16)&0xFF)
        d[26] = UInt8((r>>8)&0xFF); d[27] = UInt8(r&0xFF)
        return d
    }

    private func buildPDOLData(_ pdol: Data) -> Data {
        let total = getTotalPDOLLength(pdol)
        var result = Data(count: total)
        var ro = 0; var i = 0; let bytes = [UInt8](pdol)
        while i < bytes.count {
            var tb: [UInt8] = []
            if (bytes[i] & 0x1F) == 0x1F && i + 1 < bytes.count {
                tb = [bytes[i], bytes[i+1]]; i += 2
            } else { tb = [bytes[i]]; i += 1 }
            guard i < bytes.count else { break }
            let len = Int(bytes[i]); i += 1
            guard ro + len <= result.count else { break }

            if tb == [0x9F, 0x66] && len == 4 { result[ro] = 0x27; result[ro+1] = 0x80 }
            else if tb == [0x9F, 0x02] && len == 6 { result[ro+len-1] = 0x01 }
            else if tb == [0x9F, 0x1A] && len == 2 { result[ro] = 0x08; result[ro+1] = 0x40 }
            else if tb == [0x5F, 0x2A] && len == 2 { result[ro] = 0x08; result[ro+1] = 0x40 }
            else if tb == [0x9A] && len == 3 {
                let c = Calendar.current; let now = Date()
                let y = c.component(.year, from: now) % 100; let m = c.component(.month, from: now); let d = c.component(.day, from: now)
                result[ro] = UInt8((y/10)<<4|(y%10)); result[ro+1] = UInt8((m/10)<<4|(m%10)); result[ro+2] = UInt8((d/10)<<4|(d%10))
            }
            else if tb == [0x9C] && len == 1 { result[ro] = 0x00 }
            else if tb == [0x9F, 0x37] && len == 4 {
                let r = UInt32.random(in: 0...UInt32.max)
                result[ro] = UInt8((r>>24)&0xFF); result[ro+1] = UInt8((r>>16)&0xFF)
                result[ro+2] = UInt8((r>>8)&0xFF); result[ro+3] = UInt8(r&0xFF)
            }
            ro += len
        }
        return result
    }

    private func getTotalPDOLLength(_ pdol: Data) -> Int {
        var t = 0; var i = 0; let b = [UInt8](pdol)
        while i < b.count {
            if (b[i] & 0x1F) == 0x1F && i+1 < b.count { i += 2 } else { i += 1 }
            if i < b.count { t += Int(b[i]); i += 1 }
        }
        return t
    }
}

// MARK: - TLV Parsing & Data Extraction
extension NfcCardReaderPlugin {

    private func parseTLV(_ data: Data) -> [(tag: Data, value: Data)] {
        var result: [(tag: Data, value: Data)] = []
        var i = 0; let bytes = [UInt8](data)
        while i < bytes.count {
            if bytes[i] == 0x00 || bytes[i] == 0xFF { i += 1; continue }
            guard i + 1 < bytes.count else { break }

            let tag: Data
            if (bytes[i] & 0x1F) == 0x1F {
                var tb = [bytes[i]]; i += 1
                while i < bytes.count { tb.append(bytes[i]); if (bytes[i] & 0x80) == 0 { break }; i += 1 }
                i += 1; tag = Data(tb)
            } else { tag = Data([bytes[i]]); i += 1 }

            guard i < bytes.count else { break }
            var length = Int(bytes[i]); i += 1
            if length == 0x81 { guard i < bytes.count else { break }; length = Int(bytes[i]); i += 1 }
            else if length == 0x82 { guard i+1 < bytes.count else { break }; length = (Int(bytes[i])<<8)|Int(bytes[i+1]); i += 2 }
            else if length > 127 {
                let n = length & 0x7F; guard i+n <= bytes.count else { break }
                length = 0; for _ in 0..<n { length = (length<<8)|Int(bytes[i]); i += 1 }
            }
            guard length >= 0, i + length <= bytes.count else { break }
            let value = Data(bytes[i..<(i+length)])
            result.append((tag: tag, value: value))
            if (tag[0] & 0x20) != 0 { result.append(contentsOf: parseTLV(value)) }
            i += length
        }
        return result
    }

    private func extractAllAIDs(from data: Data) -> [Data] {
        var aids: [Data] = []
        for (tag, value) in parseTLV(data) {
            if tag == Data([0x4F]) { aids.append(value) }
        }
        return aids
    }

    private func extractPDOL(from data: Data) -> Data? {
        for (tag, value) in parseTLV(data) {
            if tag == Data([0x9F, 0x38]) { return value }
        }
        return nil
    }

    private func extractAFL(from data: Data) -> [(sfi: Int, rec: Int)] {
        var records: [(sfi:Int,rec:Int)] = []
        for (tag, value) in parseTLV(data) {
            if tag == Data([0x94]) {
                let b = [UInt8](value); var i = 0
                while i+3 < b.count {
                    let sfi = Int(b[i]) >> 3; let f = Int(b[i+1]); let l = Int(b[i+2])
                    if f <= l && sfi > 0 { for r in f...l { records.append((sfi:sfi,rec:r)) } }
                    i += 4
                }
            } else if tag == Data([0x80]) && value.count >= 6 {
                let b = [UInt8](value); var i = 2
                while i+3 < b.count {
                    let sfi = Int(b[i]) >> 3; let f = Int(b[i+1]); let l = Int(b[i+2])
                    if f <= l && sfi > 0 { for r in f...l { records.append((sfi:sfi,rec:r)) } }
                    i += 4
                }
            }
        }
        if records.isEmpty {
            for s in 1...3 { for r in 1...5 { records.append((sfi:s,rec:r)) } }
        }
        return records
    }

    private func extractCardData(from data: Data) -> [String: Any?]? {
        var cn: String?; var exp: String?; var name: String?
        for (tag, value) in parseTLV(data) {
            if tag == Data([0x57]) {
                let t2 = parseTrack2(value)
                if cn == nil { cn = t2?.pan }; if exp == nil { exp = t2?.expiry }
            } else if tag == Data([0x5A]) {
                if cn == nil { cn = formatPAN(toHex(value).replacingOccurrences(of: "F", with: "")) }
            } else if tag == Data([0x5F, 0x24]) {
                if exp == nil { exp = formatExp(toHex(value)) }
            } else if tag == Data([0x5F, 0x20]) {
                if name == nil {
                    name = String(data: value, encoding: .ascii)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "/", with: " ")
                }
            }
        }
        guard cn != nil || exp != nil || name != nil else { return nil }
        return ["cardNumber": cn, "expirationDate": exp, "cardholderName": name]
    }

    private func parseTrack2(_ data: Data) -> (pan: String, expiry: String)? {
        let hex = toHex(data)
        guard let sep = hex.range(of: "D") ?? hex.range(of: "=") else { return nil }
        let pan = String(hex[hex.startIndex..<sep.lowerBound])
        let after = hex[sep.upperBound...]
        guard after.count >= 4 else { return nil }
        return (pan: formatPAN(pan.replacingOccurrences(of: "F", with: "")),
                expiry: formatExp(String(after.prefix(4))))
    }

    private func formatPAN(_ pan: String) -> String {
        var r = ""; for (i,c) in pan.enumerated() { if i > 0 && i % 4 == 0 { r += " " }; r += String(c) }; return r
    }

    private func formatExp(_ date: String) -> String {
        guard date.count >= 4 else { return date }
        let ye = date.index(date.startIndex, offsetBy: 2)
        let me = date.index(ye, offsetBy: 2)
        return "\(date[ye..<me])/\(date[date.startIndex..<ye])"
    }
}
