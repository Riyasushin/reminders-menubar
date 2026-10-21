import EventKit

struct ReminderSearchDocument {
    let reminder: EKReminder
    let title: String
    let notes: String
    let urlString: String
    let tagNames: [String]
    let isCompleted: Bool
}

@MainActor
class RemindersService {
    static let shared = RemindersService()
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
    }
    
    private let eventStore = EKEventStore()
    
    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized
        }
    }
    
    func requestAccess(completion: @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                completion(granted, error?.localizedDescription)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                completion(granted, error?.localizedDescription)
            }
        }
    }
    
    func getCalendar(withIdentifier calendarIdentifier: String) -> EKCalendar? {
        return eventStore.calendar(withIdentifier: calendarIdentifier)
    }
    
    func getCalendars() -> [EKCalendar] {
        return eventStore.calendars(for: .reminder)
    }
    
    func getDefaultCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
    }
    
    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { allReminders in
                guard let allReminders else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: allReminders)
            }
        }
    }

    private func createReminderItems(for reminders: [EKReminder]) -> [ReminderItem] {
        var reminderItems: [ReminderItem] = []

        let reminderIds = Set(reminders.map(\.calendarItemIdentifier))
        let remindersByParentId = Dictionary(grouping: reminders, by: { $0.parentId })
        let parentReminders = reminders.filter { reminder in
            guard let parentId = reminder.parentId else { return true }
            return !reminderIds.contains(parentId)
        }

        parentReminders.forEach { parentReminder in
            let parentId = parentReminder.calendarItemIdentifier
            let children = remindersByParentId[parentId, default: []].map({ ReminderItem(for: $0, isChild: true) })
            reminderItems.append(ReminderItem(for: parentReminder, withChildren: children))
        }
        return reminderItems
    }

    /// nil searches every reminder calendar. An empty list searches none.
    func fetchIncompleteReminders(calendarIdentifiers: [String]?) async -> [EKReminder] {
        let calendars = incompleteCalendars(for: calendarIdentifiers)
        if let calendars, calendars.isEmpty {
            return []
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        return await fetchReminders(matching: predicate)
    }

    func calendarReminderLists(
        from reminders: [EKReminder],
        calendarIdentifiers: [String]
    ) -> [CalendarReminderList] {
        let calendars = getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
        let remindersByCalendar = Dictionary(grouping: reminders, by: { $0.calendar.calendarIdentifier })

        return calendars.map { calendar in
            let calendarReminders = remindersByCalendar[calendar.calendarIdentifier, default: []]
            let reminderItems = createReminderItems(for: calendarReminders)
            return CalendarReminderList(for: calendar, with: reminderItems)
        }
    }

    func getRecentReminders() async -> [ReminderItem] {
        let allReminders = await fetchAllReminders()
        return recentReminderItems(from: allReminders)
    }

    func recentReminderItems(from reminders: [EKReminder], now: Date = Date()) -> [ReminderItem] {
        let recentRemindersDayCount = 90
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -recentRemindersDayCount,
            to: now
        ) ?? Date.distantPast

        return reminders
            .filter { ($0.lastModifiedDate ?? .distantPast) >= cutoffDate }
            .map { ReminderItem(for: $0) }
            .sorted { ($0.lastModifiedDate ?? .distantPast) > ($1.lastModifiedDate ?? .distantPast) }
    }

    func upcomingReminderItems(
        from reminders: [EKReminder],
        interval: ReminderInterval,
        calendarIdentifiers: [String]?
    ) -> [ReminderItem] {
        var matched = remindersLimited(reminders, to: calendarIdentifiers)
            .filter { matchesUpcomingInterval($0, ending: interval.endingDate) }
        if interval == .due {
            // For the 'due' interval, we should filter reminders for today with no time.
            // These will only be considered due/expired on the following day.
            matched = matched.filter(\.isExpired)
        }
        return matched.map({ ReminderItem(for: $0) }).sortedUpcomingReminders
    }

    func incompleteCount(from reminders: [EKReminder], calendarIdentifiers: [String]?) -> Int {
        remindersLimited(reminders, to: calendarIdentifiers).count
    }
    
    func save(reminder: EKReminder) {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            print("Error saving reminder:", error.localizedDescription)
        }
    }

    func save(reminder: EKReminder, tags: [Tag], isFlagged: Bool, isUrgent: Bool) {
        save(reminder: reminder)
        reminder.updateTags(tags)
        if #available(macOS 26, *) {
            reminder.updateUrgent(isUrgent)
        }
        reminder.updateFlagged(isFlagged)
    }
    
    func createNew(with rmbReminder: RmbReminder, in calendar: EKCalendar) {
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.update(with: rmbReminder)
        newReminder.calendar = calendar
        save(
            reminder: newReminder,
            tags: rmbReminder.tags,
            isFlagged: rmbReminder.isFlagged,
            isUrgent: rmbReminder.isUrgent
        )
    }
    
    func fetchAllReminders() async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await fetchReminders(matching: predicate)
    }

    func tags(in reminders: [EKReminder]) -> [Tag] {
        var tags: Set<Tag> = []
        for reminder in reminders {
            for tag in reminder.ekTags {
                tags.insert(tag)
            }
        }
        return tags.sorted()
    }

    func tagReminderLists(
        from reminders: [EKReminder],
        tags: [Tag],
        calendarIdentifiers: [String]?
    ) -> [TagReminderList] {
        guard !tags.isEmpty else { return [] }

        if let calendarIdentifiers {
            let selectedCalendars = getCalendars().filter {
                calendarIdentifiers.contains($0.calendarIdentifier)
            }
            guard !selectedCalendars.isEmpty else {
                return tags.map { TagReminderList(for: $0, with: []) }
            }
        }

        let scopedReminders = remindersLimited(reminders, to: calendarIdentifiers)
        let selectedTags = Set(tags)
        var remindersByTag: [Tag: [EKReminder]] = [:]
        for reminder in scopedReminders {
            for tag in reminder.ekTags where selectedTags.contains(tag) {
                remindersByTag[tag, default: []].append(reminder)
            }
        }

        return tags.map { tag in
            let reminderItems = createReminderItems(for: remindersByTag[tag, default: []])
            return TagReminderList(for: tag, with: reminderItems)
        }
    }

    private func incompleteCalendars(for calendarIdentifiers: [String]?) -> [EKCalendar]? {
        guard let calendarIdentifiers else {
            return nil
        }
        return getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
    }

    private func remindersLimited(
        _ reminders: [EKReminder],
        to calendarIdentifiers: [String]?
    ) -> [EKReminder] {
        guard let calendarIdentifiers else {
            return reminders
        }
        if calendarIdentifiers.isEmpty {
            return []
        }
        let allowedIdentifiers = Set(calendarIdentifiers)
        return reminders.filter({ allowedIdentifiers.contains($0.calendar.calendarIdentifier) })
    }

    // EventKit includes a dated reminder when its due date is on or before `ending`.
    // A nil ending is unbounded and also includes reminders with no due date.
    private func matchesUpcomingInterval(_ reminder: EKReminder, ending: Date?) -> Bool {
        guard let ending else {
            return true
        }
        guard let dueDate = reminder.dueDateComponents?.date else {
            return false
        }
        return dueDate <= ending
    }

    func makeSearchDocuments(from reminders: [EKReminder]) -> [ReminderSearchDocument] {
        reminders.map { reminder in
            ReminderSearchDocument(
                reminder: reminder,
                title: (reminder.title ?? "").lowercased(),
                notes: (reminder.notes ?? "").lowercased(),
                urlString: reminder.attachedUrl?.absoluteString.lowercased() ?? "",
                tagNames: reminder.ekTags.map({ $0.name.lowercased() }),
                isCompleted: reminder.isCompleted
            )
        }
    }

    func searchReminders(matching query: String, in documents: [ReminderSearchDocument]) -> [ReminderItem] {
        let queryWords = query
            .lowercased()
            .split(separator: " ")
            .map { (word: String($0), tagWord: $0.hasPrefix("#") ? String($0.dropFirst()) : nil) }
        guard !queryWords.isEmpty else { return [] }

        let scored: [(ReminderItem, Int)] = documents.compactMap { document in
            let allFields = [document.title, document.notes, document.urlString] + document.tagNames

            let allWordsMatch = queryWords.allSatisfy { word, tagWord in
                if let tagWord, !tagWord.isEmpty,
                   document.tagNames.contains(where: { $0.contains(tagWord) }) {
                    return true
                }
                return allFields.contains { $0.contains(word) }
            }
            guard allWordsMatch else { return nil }

            var score = 0
            for (word, tagWord) in queryWords {
                if document.title.contains(word) { score += 3 }
                if document.notes.contains(word) { score += 2 }
                if document.tagNames.contains(where: { $0.contains(tagWord ?? word) }) { score += 2 }
                if document.urlString.contains(word) { score += 1 }
            }
            if !document.isCompleted { score += 1 }

            return (ReminderItem(for: document.reminder), score)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    func remove(reminder: EKReminder) {
        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Error removing reminder:", error.localizedDescription)
        }
    }
}
