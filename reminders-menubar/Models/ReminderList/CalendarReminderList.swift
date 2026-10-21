import EventKit

struct CalendarReminderList: Identifiable, Equatable {
    let id: String
    let calendar: EKCalendar
    let reminders: [ReminderItem]
    
    init(for calendar: EKCalendar, with reminderItems: [ReminderItem], preservesOrder: Bool = false) {
        self.id = calendar.calendarIdentifier
        self.calendar = calendar
        self.reminders = preservesOrder ? reminderItems : reminderItems.sortedReminders
    }
}
