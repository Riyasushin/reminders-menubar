import EventKit

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let reminder: EKReminder
    let lastModifiedDate: Date?
    let childReminders: [ReminderItem]
    let isChild: Bool
    let hasChildren: Bool
    
    init(for reminder: EKReminder, isChild: Bool = false, withChildren childReminders: [ReminderItem] = []) {
        self.id = reminder.calendarItemIdentifier
        self.reminder = reminder
        self.lastModifiedDate = reminder.lastModifiedDate
        self.childReminders = childReminders.sortedReminders
        self.isChild = isChild
        self.hasChildren = !childReminders.isEmpty
    }
    
    func resorted() -> ReminderItem {
        ReminderItem(
            for: reminder,
            isChild: isChild,
            withChildren: childReminders.map { $0.resorted() }
        )
    }

    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        return (
            lhs.id == rhs.id
            && lhs.lastModifiedDate == rhs.lastModifiedDate
            && lhs.childReminders == rhs.childReminders
        )
    }
}
