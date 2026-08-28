import AppKit
import Combine
import CryptoKit
import ServiceManagement
import SwiftUI

private let defaultOutputFileName = "messenger_7day_updates.json"
private let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

struct StoredMessage: Hashable {
    let id: String
    let conversation: String
    let sentAt: String
    let sender: String
    let type: String
    let text: String
}

struct OutputMessage: Codable {
    let id: String
    let sentAt: String
    let sender: String
    let type: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case id, sender, type, text
        case sentAt = "sent_at"
    }
}

struct OutputConversation: Codable {
    let name: String
    let messageCount: Int
    let messages: [OutputMessage]

    enum CodingKeys: String, CodingKey {
        case name, messages
        case messageCount = "message_count"
    }
}

struct OutputDocument: Codable {
    let updatedAt: String
    let windowDays: Int
    let windowHours: Int
    let totalMessages: Int
    let conversations: [OutputConversation]

    enum CodingKeys: String, CodingKey {
        case conversations
        case updatedAt = "updated_at"
        case windowDays = "window_days"
        case windowHours = "window_hours"
        case totalMessages = "total_messages"
    }
}

private struct DOMPayload: Decodable {
    let conversation: String
    let messages: [String]
}

private enum ChromeReader {
    static let javascript = #"""
    (() => {
        const main = document.querySelector('[role="main"]');
        if (!main) return null;

        const heading = main.querySelector('h2')?.innerText?.trim() || '';
        let conversation = heading || document.title;

        let match = heading.match(/^標題為「(.+)」的對話$/);
        if (match) conversation = match[1];
        match = heading.match(/^與(.+)的對話$/);
        if (match) conversation = match[1];
        match = heading.match(/^(?:Conversation|Chat) with\s+(.+)$/i);
        if (match) conversation = match[1];
        match = heading.match(/^Conversation titled\s+(.+)$/i);
        if (match) conversation = match[1];
        match = heading.match(/^Conversación con\s+(.+)$/i);
        if (match) conversation = match[1];
        match = heading.match(/^(?:el\s+)?título(?:\s+de\s+la\s+conversación)?\s*[:：]?\s*(.+)$/i);
        if (match) conversation = match[1];

        const messages = [...main.querySelectorAll('[role="article"]')]
            .map(element => {
                const labels = [...element.querySelectorAll('[aria-label]')]
                    .map(node => node.getAttribute('aria-label')?.trim() || '')
                const accessible = labels.find(label => /(?:Message sent|Mensaje enviado|訊息已在)/i.test(label))
                    || labels.find(label => /(?:At\s+|A las\s+|在\s*\d)/i.test(label));
                return accessible || element.innerText.trim();
            })
            .filter(Boolean);

        return JSON.stringify({ conversation, messages });
    })()
    """#

    static let appleScript = #"""
    on run argv
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set targetTab to active tab of front window
            if (URL of targetTab does not contain "messenger.com") then return ""
            return execute targetTab javascript (item 1 of argv)
        end tell
    end run
    """#

    static func read() -> DOMPayload? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-", javascript]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(appleScript.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try output.fileHandleForReading.readToEnd(),
                  !data.isEmpty else { return nil }

            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "null", let json = value.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(DOMPayload.self, from: json)
        } catch {
            return nil
        }
    }
}

@MainActor
final class CollectorModel: ObservableObject {
    @Published var folder: URL
    @Published var isRunning = false
    @Published var status = "Stopped"
    @Published var activity = "Set the record file path and name, then click Start"
    @Published var currentConversation = "—"
    @Published var currentConversationCount = 0
    @Published var totalCount = 0
    @Published var lastUpdate: Date?
    @Published var fileName: String
    @Published var folderPath: String
    @Published var retentionDays: Int
    @Published var launchAtLogin: Bool

    private var messagesByID: [String: StoredMessage] = [:]
    private var timer: Timer?
    private var isPolling = false
    var fileURL: URL { folder.appendingPathComponent(normalizedFileName) }
    var normalizedFileName: String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = safe.isEmpty ? defaultOutputFileName : safe
        return base.lowercased().hasSuffix(".json") ? base : base + ".json"
    }
    private var keepInterval: TimeInterval { TimeInterval(retentionDays * 24 * 60 * 60) }

    init() {
        let defaults = UserDefaults.standard
        let oldDefaults = UserDefaults(suiteName: "tw.local.MessengerCollector")
        let migratedLaunchAtLogin = defaults.object(forKey: "launchAtLogin") == nil
            ? (oldDefaults?.bool(forKey: "launchAtLogin") ?? false)
            : defaults.bool(forKey: "launchAtLogin")

        fileName = defaults.string(forKey: "outputFileName")
            ?? oldDefaults?.string(forKey: "outputFileName")
            ?? defaultOutputFileName
        if defaults.object(forKey: "retentionDays") == nil,
           let oldDays = oldDefaults?.object(forKey: "retentionDays") as? Int {
            retentionDays = min(max(oldDays, 1), 999)
        } else {
            retentionDays = min(max(defaults.integer(forKey: "retentionDays"), 1), 999)
        }
        if defaults.object(forKey: "retentionDays") == nil,
           oldDefaults?.object(forKey: "retentionDays") == nil {
            retentionDays = 7
        }

        let savedPath = defaults.string(forKey: "outputFolder")
            ?? oldDefaults?.string(forKey: "outputFolder")
        let targetFolder = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if migratedLaunchAtLogin { try? SMAppService.mainApp.register() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let defaultFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoMissage", isDirectory: true)
        let resolvedFolder = targetFolder ?? defaultFolder
        folder = resolvedFolder
        folderPath = resolvedFolder.path
        try? FileManager.default.createDirectory(at: resolvedFolder, withIntermediateDirectories: true)
        defaults.set(resolvedFolder.path, forKey: "outputFolder")
        defaults.set(fileName, forKey: "outputFileName")
        defaults.set(retentionDays, forKey: "retentionDays")
        defaults.set(migratedLaunchAtLogin, forKey: "launchAtLogin")
        loadExisting()
    }

    func applyFileName() {
        fileName = normalizedFileName
        UserDefaults.standard.set(fileName, forKey: "outputFileName")
        loadExisting()
    }

    func updateRetentionDays(_ days: Int) {
        retentionDays = min(max(days, 1), 999)
        synchronizeFileNameWithRetention()
        UserDefaults.standard.set(retentionDays, forKey: "retentionDays")
        let removed = pruneOld()
        refreshCounts()
        if removed {
            do {
                try writeJSON()
                activity = "Retention updated to \(retentionDays) days; older messages were removed"
            } catch {
                activity = "Could not update JSON: \(error.localizedDescription)"
            }
        }
    }

    private func synchronizeFileNameWithRetention() {
        let pattern = #"_(\d+)day_"#
        guard fileName.range(of: pattern, options: .regularExpression) != nil else { return }
        let updated = fileName.replacingOccurrences(
            of: pattern,
            with: "_\(retentionDays)day_",
            options: .regularExpression
        )
        guard updated != fileName else { return }
        fileName = updated
        UserDefaults.standard.set(fileName, forKey: "outputFileName")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Messenger JSON records"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        folder = selected
        folderPath = selected.path
        UserDefaults.standard.set(selected.path, forKey: "outputFolder")
        loadExisting()
    }

    func applyFolderPath() {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            folderPath = folder.path
            return
        }
        folder = URL(fileURLWithPath: trimmed, isDirectory: true)
        folderPath = folder.path
        UserDefaults.standard.set(folder.path, forKey: "outputFolder")
        loadExisting()
    }

    func start() {
        guard !isRunning else { return }
        applyFileName()
        loadExisting()
        isRunning = true
        status = "Recording"
        activity = "Waiting for a Messenger tab in the foreground Chrome window…"
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        status = "Stopped"
        activity = "Recording paused"
    }

    private func poll() {
        guard isRunning, !isPolling else { return }
        isPolling = true
        Task {
            let payload = await Task.detached(priority: .utility) { ChromeReader.read() }.value
            isPolling = false
            guard isRunning else { return }
            if let payload { ingest(payload) }
        }
    }

    private func loadExisting() {
        messagesByID.removeAll()
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(OutputDocument.self, from: data) else {
            refreshCounts()
            return
        }

        var needsRewrite = false
        for conversation in document.conversations {
            let conversationName = normalizedConversationName(conversation.name)
            if conversationName != conversation.name { needsRewrite = true }
            for message in conversation.messages {
                let sender = normalizedSender(message.sender)
                let canonicalID = Self.messageID(
                    conversation: conversationName,
                    sentAt: message.sentAt,
                    sender: sender,
                    type: message.type,
                    text: message.text
                )
                let stored = StoredMessage(
                    id: canonicalID,
                    conversation: conversationName,
                    sentAt: message.sentAt,
                    sender: sender,
                    type: message.type,
                    text: message.text
                )
                if messagesByID[canonicalID] != nil || canonicalID != message.id || sender != message.sender {
                    needsRewrite = true
                }
                messagesByID[canonicalID] = stored
            }
        }

        let removed = pruneOld()
        refreshCounts()
        if removed || needsRewrite { try? writeJSON() }
        activity = "Loaded existing JSON: \(totalCount) messages"
    }

    private func ingest(_ payload: DOMPayload) {
        let conversation = normalizedConversationName(payload.conversation)
        guard !conversation.isEmpty else { return }
        var changed = false

        for raw in payload.messages {
            guard let parsed = parseMessage(raw), parsed.date >= Date().addingTimeInterval(-keepInterval) else { continue }
            let sentAt = Self.isoString(parsed.date)
            let id = Self.messageID(
                conversation: conversation,
                sentAt: sentAt,
                sender: parsed.sender,
                type: parsed.type,
                text: parsed.text
            )
            guard messagesByID[id] == nil else { continue }
            messagesByID[id] = StoredMessage(
                id: id,
                conversation: conversation,
                sentAt: sentAt,
                sender: parsed.sender,
                type: parsed.type,
                text: parsed.text
            )
            changed = true
        }

        let pruned = pruneOld()
        currentConversation = conversation
        refreshCounts()

        if changed || pruned {
            do {
                try writeJSON()
                lastUpdate = Date()
                activity = "\(conversation) | This conversation: \(currentConversationCount) | JSON total: \(totalCount)"
            } catch {
                activity = "Could not write JSON: \(error.localizedDescription)"
            }
        }
    }

    private func normalizedConversationName(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let lowercased = cleaned.lowercased()
            var removedPrefix = false
            for prefix in ["conversación con ", "conversation with ", "chat with ", "conversation titled ", "el título ", "título "] {
                if lowercased.hasPrefix(prefix) {
                    cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    removedPrefix = true
                    break
                }
            }
            if !removedPrefix { break }
        }
        if cleaned != value.trimmingCharacters(in: .whitespacesAndNewlines) {
            return cleaned
        }
        let headingPatterns = [
            #"(?i)^(?:Conversación con|Conversation with|Chat with|Conversation titled)\s+(.+)$"#,
            #"(?i)^(?:el\s+)?título(?:\s+de\s+la\s+conversación)?\s*[:：]?\s*(.+)$"#,
            #"^(?:與|与)(.+)(?:的對話|的对话)$"#,
            #"^標題為「(.+)」的對話$"#,
            #"^标题为「(.+)」的对话$"#
        ]
        for pattern in headingPatterns {
            if let groups = captures(pattern, in: cleaned), let name = groups.first,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }

    private func parseMessage(_ raw: String) -> (date: Date, sender: String, type: String, text: String)? {
        let textPatterns: [(String, String)] = [
            (#"^輸入，訊息已在(.+?)由(.+?)傳送(?::|：)\s*([\s\S]*)$"#, "zh"),
            (#"^Message sent\s+(.+?)\s+by\s+(.+?)(?::|：)\s*([\s\S]*)$"#, "en"),
            (#"^At\s+(.+?\d{1,2}:\d{2}\s*(?:AM|PM|am|pm))\s*,\s*(.+?)(?::|：)\s*([\s\S]*)$"#, "enAt"),
            (#"^Mensaje enviado(?::)?\s+(.+?)\s+por(?::)?\s+(.+?)(?::|：)\s*([\s\S]*)$"#, "es"),
            (#"^A las\s+(.+?),\s*(.+?)(?::|：)\s*([\s\S]*)$"#, "esAt")
        ]

        for (pattern, language) in textPatterns {
            let marker: String
            switch language {
            case "zh": marker = "輸入，訊息已在"
            case "en": marker = "Message sent"
            case "enAt": marker = "At "
            case "es": marker = "Mensaje enviado"
            default: marker = "A las "
            }
            guard let markerRange = raw.range(of: marker, options: .backwards) else { continue }
            let metadata = String(raw[markerRange.lowerBound...])
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: metadata, range: NSRange(metadata.startIndex..., in: metadata)),
                  match.numberOfRanges == 4,
                  let timeRange = Range(match.range(at: 1), in: metadata),
                  let senderRange = Range(match.range(at: 2), in: metadata),
                  let textRange = Range(match.range(at: 3), in: metadata) else { continue }

            let timeText = String(metadata[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let date = parseMessengerTime(timeText)
            guard let date else { continue }
            let sender = normalizedSender(String(metadata[senderRange]))
            let text = String(metadata[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (date, sender, text.isEmpty ? "non_text" : "text", text)
        }

        let nonTextPatterns: [(String, String)] = [
            (#"^輸入，訊息已在(.+?)由(.+?)傳送$"#, "zh"),
            (#"^Message sent\s+(.+?)\s+by\s+(.+?)$"#, "en"),
            (#"^At\s+(.+?\d{1,2}:\d{2}\s*(?:AM|PM|am|pm))\s*,\s*(.+?)$"#, "enAt"),
            (#"^Mensaje enviado(?::)?\s+(.+?)\s+por(?::)?\s+(.+?)$"#, "es"),
            (#"^A las\s+(.+?),\s*(.+?)$"#, "esAt")
        ]

        for (pattern, language) in nonTextPatterns {
            let marker: String
            switch language {
            case "zh": marker = "輸入，訊息已在"
            case "en": marker = "Message sent"
            case "enAt": marker = "At "
            case "es": marker = "Mensaje enviado"
            default: marker = "A las "
            }
            guard let markerRange = raw.range(of: marker, options: .backwards) else { continue }
            let metadata = String(raw[markerRange.lowerBound...])
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: metadata, range: NSRange(metadata.startIndex..., in: metadata)),
                  match.numberOfRanges == 3,
                  let timeRange = Range(match.range(at: 1), in: metadata),
                  let senderRange = Range(match.range(at: 2), in: metadata) else { continue }
            let timeText = String(metadata[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = parseMessengerTime(timeText) else { continue }
            let sender = normalizedSender(String(metadata[senderRange]))
            return (date, sender, "non_text", "")
        }
        return nil
    }

    private func normalizedSender(_ value: String) -> String {
        let sender = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender.lowercased() {
        case "you", "tú", "tu", "你", "妳", "您":
            return "You"
        default:
            return sender
        }
    }

    private func parseMessengerTime(_ value: String) -> Date? {
        let normalizedValue = normalizeMessengerWhitespace(value)
        if let weekdayDate = parseChineseWeekdayTime(normalizedValue) {
            return weekdayDate
        }
        if let spanishDate = parseSpanishMessengerTime(normalizedValue) {
            return spanishDate
        }
        let fullPattern = #"^(\d{4})年(\d{1,2})月(\d{1,2})日\s*(?:(上午|下午)\s*)?(\d{1,2}):(\d{2})$"#
        if let groups = captures(fullPattern, in: normalizedValue), groups.count == 6,
           let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2]),
           let rawHour = Int(groups[4]), let minute = Int(groups[5]) {
            let hour = convertedHour(rawHour, period: groups[3])
            return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        }

        let todayPattern = #"^(上午|下午)\s*(\d{1,2}):(\d{2})$"#
        if let groups = captures(todayPattern, in: normalizedValue), groups.count == 3,
           let rawHour = Int(groups[1]), let minute = Int(groups[2]) {
            let now = Date()
            let hour = convertedHour(rawHour, period: groups[0])
            guard var result = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            if result > now.addingTimeInterval(5 * 60) {
                result = Calendar.current.date(byAdding: .day, value: -1, to: result) ?? result
            }
            return result
        }
        return parseEnglishMessengerTime(normalizedValue)
    }

    private func normalizeMessengerWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseSpanishMessengerTime(_ value: String) -> Date? {
        let cleaned = normalizeMessengerWhitespace(value)
        let calendar = Calendar.current
        let now = Date()
        let months = [
            "enero", "febrero", "marzo", "abril", "mayo", "junio",
            "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"
        ]

        let fullPattern = #"^(\d{1,2}) de ([[:alpha:]]+) de (\d{4}),\s*(\d{1,2}):(\d{2})\s*(am|pm)$"#
        if let groups = captures(fullPattern, in: cleaned), groups.count == 6,
           let day = Int(groups[0]), let year = Int(groups[2]),
           let rawHour = Int(groups[3]), let minute = Int(groups[4]),
           let month = months.firstIndex(of: groups[1].lowercased()) {
            let hour = convertedEnglishHour(rawHour, period: groups[5])
            return calendar.date(from: DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute))
        }

        let weekdayPattern = #"^(domingo|lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado)\s+(\d{1,2}):(\d{2})$"#
        if let groups = captures(weekdayPattern, in: cleaned), groups.count == 3,
           let rawHour = Int(groups[1]), let minute = Int(groups[2]) {
            let weekdays = ["domingo", "lunes", "martes", "miércoles", "miercoles", "jueves", "viernes", "sábado", "sabado"]
            let normalizedWeekday = groups[0].lowercased()
                .replacingOccurrences(of: "miercoles", with: "miércoles")
                .replacingOccurrences(of: "sabado", with: "sábado")
            guard let targetName = weekdays.first(where: { $0 == normalizedWeekday }),
                  let targetWeekday = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"].firstIndex(of: targetName) else { return nil }
            var candidate = calendar.date(bySettingHour: rawHour, minute: minute, second: 0, of: now)
            for _ in 0..<8 {
                if let date = candidate, calendar.component(.weekday, from: date) == targetWeekday + 1,
                   date <= now.addingTimeInterval(5 * 60) {
                    return date
                }
                candidate = candidate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
            }
        }

        return nil
    }

    private func convertedEnglishHour(_ hour: Int, period: String) -> Int {
        let normalized = period.lowercased()
        if normalized == "am" && hour == 12 { return 0 }
        if normalized == "pm" && hour != 12 { return hour + 12 }
        return hour
    }

    private func parseChineseWeekdayTime(_ value: String) -> Date? {
        let cleaned = normalizeMessengerWhitespace(value)
        let pattern = #"^(?:星期|週|禮拜|礼拜)(日|天|一|二|三|四|五|六)\s*(上午|下午)?\s*(\d{1,2}):(\d{2})$"#
        guard let groups = captures(pattern, in: cleaned), groups.count == 4,
              let rawHour = Int(groups[2]), let minute = Int(groups[3]) else { return nil }
        let hour: Int
        if groups[1] == "下午" {
            hour = rawHour == 12 ? 12 : rawHour + 12
        } else if groups[1] == "上午" {
            hour = rawHour == 12 ? 0 : rawHour
        } else {
            hour = rawHour
        }
        let weekdayMap = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        guard let targetWeekday = weekdayMap[groups[0]] else { return nil }
        let calendar = Calendar.current
        let now = Date()
        var candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
        for _ in 0..<8 {
            if let date = candidate, calendar.component(.weekday, from: date) == targetWeekday,
               date <= now.addingTimeInterval(5 * 60) {
                return date
            }
            candidate = candidate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
        }
        return nil
    }

    private func parseEnglishMessengerTime(_ value: String) -> Date? {
        let cleaned = normalizeMessengerWhitespace(value)
            .replacingOccurrences(of: "^At\\s+", with: "", options: .regularExpression)
        let now = Date()
        let calendar = Calendar.current

        let weekdayPattern = #"^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday),?\s+(\d{1,2}):(\d{2})\s*(AM|PM|am|pm)$"#
        if let groups = captures(weekdayPattern, in: cleaned), groups.count == 4,
           let rawHour = Int(groups[1]), let minute = Int(groups[2]) {
            let hour = groups[3].lowercased() == "pm" && rawHour != 12
                ? rawHour + 12
                : (groups[3].lowercased() == "am" && rawHour == 12 ? 0 : rawHour)
            let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            guard let targetWeekday = weekdays.firstIndex(of: groups[0]) else { return nil }
            var candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            for _ in 0..<8 {
                if let date = candidate, calendar.component(.weekday, from: date) == targetWeekday + 1,
                   date <= now.addingTimeInterval(5 * 60) {
                    return date
                }
                candidate = candidate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
            }
        }

        let relativePattern = #"^(Today|Yesterday) at (\d{1,2}):(\d{2})\s*(AM|PM|am|pm)$"#
        if let groups = captures(relativePattern, in: cleaned), groups.count == 4,
           let rawHour = Int(groups[1]), let minute = Int(groups[2]) {
            let hour = groups[3].lowercased() == "pm" && rawHour != 12
                ? rawHour + 12
                : (groups[3].lowercased() == "am" && rawHour == 12 ? 0 : rawHour)
            var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            if groups[0] == "Yesterday" {
                date = date.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
            }
            return date
        }

        let formats = [
            "EEEE h:mma", "EEEE h:mm a", "EEEE, h:mma", "EEEE, h:mm a",
            "MMMM d 'at' h:mma", "MMMM d 'at' h:mm a",
            "MMMM d, yyyy, h:mma", "MMMM d, yyyy, h:mm a",
            "EEEE, MMMM d, yyyy 'at' h:mma", "EEEE, MMMM d, yyyy 'at' h:mm a",
            "MMMM d, yyyy 'at' h:mma", "MMMM d, yyyy 'at' h:mm a",
            "yyyy-MM-dd HH:mm"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: cleaned) {
                if format.contains("yyyy") || format.hasPrefix("yyyy") { return parsed }
                var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
                components.year = calendar.component(.year, from: now)
                if let result = calendar.date(from: components) {
                    return result > now.addingTimeInterval(5 * 60)
                        ? calendar.date(byAdding: .year, value: -1, to: result)
                        : result
                }
            }
        }
        return nil
    }

    private func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
            return String(value[swiftRange])
        }
    }

    private func convertedHour(_ hour: Int, period: String) -> Int {
        if period == "上午", hour == 12 { return 0 }
        if period == "下午", hour != 12 { return hour + 12 }
        return hour
    }

    @discardableResult
    private func pruneOld() -> Bool {
        let cutoff = Date().addingTimeInterval(-keepInterval)
        let oldCount = messagesByID.count
        messagesByID = messagesByID.filter { _, message in
            guard let date = Self.parseISO(message.sentAt) else { return false }
            return date >= cutoff
        }
        return messagesByID.count != oldCount
    }

    private func refreshCounts() {
        totalCount = messagesByID.count
        currentConversationCount = messagesByID.values.filter { $0.conversation == currentConversation }.count
    }

    private func writeJSON() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grouped = Dictionary(grouping: messagesByID.values, by: \.conversation)
        let conversations = grouped.map { name, stored in
            let sorted = stored.sorted { $0.sentAt < $1.sentAt }
            return OutputConversation(
                name: name,
                messageCount: sorted.count,
                messages: sorted.map { OutputMessage(id: $0.id, sentAt: $0.sentAt, sender: $0.sender, type: $0.type, text: $0.text) }
            )
        }.sorted { ($0.messages.last?.sentAt ?? "") > ($1.messages.last?.sentAt ?? "") }

        let document = OutputDocument(
            updatedAt: Self.isoString(Date()),
            windowDays: retentionDays,
            windowHours: retentionDays * 24,
            totalMessages: messagesByID.count,
            conversations: conversations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    private static func messageID(conversation: String, sentAt: String, sender: String, type: String, text: String) -> String {
        let source = [conversation, sentAt, sender, type, text].joined(separator: "\n")
        return SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    private static func parseISO(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.date(from: value)
    }
}

struct ContentView: View {
    @ObservedObject var model: CollectorModel
    @FocusState private var focusedField: InputField?

    private enum InputField {
        case folderPath
        case fileName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Record File").font(.headline.bold())
                HStack(spacing: 8) {
                    Text("Path:").frame(width: 44, alignment: .leading)
                    TextField("", text: $model.folderPath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .folderPath)
                        .onSubmit {
                            model.applyFolderPath()
                            focusedField = nil
                        }
                    Button { model.chooseFolder() } label: {
                        Text("Browse").frame(width: 54)
                    }
                    .frame(width: 76)
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                }
                .disabled(model.isRunning)
                HStack(spacing: 8) {
                    Text("Name:").frame(width: 44, alignment: .leading)
                    TextField(defaultOutputFileName, text: $model.fileName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .fileName)
                        .onSubmit {
                            model.applyFileName()
                            focusedField = nil
                        }
                    Button { model.applyFileName() } label: {
                        Text("Apply").frame(width: 54)
                    }
                    .frame(width: 76)
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                }
                .disabled(model.isRunning)

                HStack(spacing: 8) {
                    Text("Range:").frame(width: 44, alignment: .leading)
                    TextField("", value: Binding(
                        get: { model.retentionDays },
                        set: { model.updateRetentionDays($0) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                    Text("days")
                    Stepper("", value: Binding(
                        get: { model.retentionDays },
                        set: { model.updateRetentionDays($0) }
                    ), in: 1...999)
                    .labelsHidden()
                    .controlSize(.small)
                }
                .disabled(model.isRunning)

                HStack(spacing: 4) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    .labelsHidden()
                    Text("Launch and start recording at login")
                }
            }

            Divider()

            HStack {
                Circle().fill(model.isRunning ? Color.green : Color.gray).frame(width: 10, height: 10)
                Text(model.status).font(.headline)
                Spacer()
                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                        Text(model.isRunning ? "Stop" : "Start")
                        .frame(width: 54)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(width: 76)
                .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
            }

            Text(model.activity).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.currentConversation).font(.headline)
                    HStack(spacing: 24) {
                        Label("This conversation: \(model.currentConversationCount)", systemImage: "bubble.left.and.bubble.right")
                        Label("JSON total: \(model.totalCount)", systemImage: "doc.text")
                    }
                    if let date = model.lastUpdate {
                        Text("Last updated: \(displayDateFormatter.string(from: date))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Warning: Records are stored as unencrypted JSON. Please protect the file and consider data privacy.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("NoMissage © 2026 WhARTS Ltd.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .padding(24)
        .frame(width: 600)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let model: CollectorModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem()
    private let countMenuItem = NSMenuItem()
    private let toggleMenuItem = NSMenuItem()
    private var cancellables = Set<AnyCancellable>()
    private let openSettings: () -> Void

    init(model: CollectorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        super.init()

        statusMenuItem.isEnabled = false
        countMenuItem.isEnabled = false
        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleCollection)

        menu.addItem(statusMenuItem)
        menu.addItem(countMenuItem)
        menu.addItem(.separator())
        menu.addItem(toggleMenuItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit App", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.autoenablesItems = false
        statusItem.menu = menu

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        statusItem.button?.image = makeImage(isRunning: model.isRunning)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = model.isRunning ? "NoMissage is recording" : "NoMissage is stopped"
        statusMenuItem.title = model.isRunning ? "NoMissage is recording" : "NoMissage is stopped"
        countMenuItem.title = "JSON total: \(model.totalCount)"
        toggleMenuItem.title = model.isRunning ? "Stop recording" : "Start recording"
    }

    private func makeImage(isRunning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let bubbleColor = NSColor.white
        bubbleColor.setFill()
        // A larger radius gives the speech bubble the soft, friendly shape of 💬.
        let bubble = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 14, height: 12), xRadius: 6, yRadius: 6)
        bubble.fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4, y: 5))
        tail.curve(to: NSPoint(x: 3, y: 1), controlPoint1: NSPoint(x: 4, y: 3), controlPoint2: NSPoint(x: 3, y: 2))
        tail.curve(to: NSPoint(x: 9, y: 5), controlPoint1: NSPoint(x: 5, y: 2), controlPoint2: NSPoint(x: 7, y: 4))
        tail.close()
        tail.fill()

        if isRunning {
            let indicatorRect = NSRect(x: 13, y: 1, width: 5, height: 5)
            let indicator = NSBezierPath(ovalIn: indicatorRect)
            NSColor.systemGreen.setFill()
            indicator.fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func toggleCollection() {
        model.isRunning ? model.stop() : model.start()
        refresh()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CollectorModel()
    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingController = NSHostingController(rootView: ContentView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "NoMissage"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 550))
        window.center()
        settingsWindow = window

        statusController = StatusItemController(model: model) { [weak self] in
            self?.showSettings()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        guard let window = settingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.stop()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}

@main
struct NoMissageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
