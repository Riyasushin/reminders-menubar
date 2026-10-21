import Foundation

struct TagReminderList: Identifiable, Equatable {
    var id: String { tag.id }
    let tag: Tag
    let reminders: [ReminderItem]

    init(for tag: Tag, with reminderItems: [ReminderItem], preservesOrder: Bool = false) {
        self.tag = tag
        self.reminders = preservesOrder ? reminderItems : reminderItems.sortedReminders
    }
}
