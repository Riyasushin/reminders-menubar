import SwiftUI
import Combine
import EventKit

@MainActor
class RemindersData: ObservableObject {
    private var cancellationTokens: [AnyCancellable] = []
    private let previewService = MenuBarPreviewService()
    private var incompleteReminders: [EKReminder] = []
    private var incompleteSnapshotScope: IncompleteCalendarScope?

    init() {
        addObservers()
        Task {
            await update()
        }
    }

    private func addObservers() {
        addDataObservers()
        addUpcomingObservers()
        addTagObservers()
        addMenuBarObservers()
        addSearchObservers()
        addSectionOrderObservers()
    }

    private func addDataObservers() {
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: .remindersDataShouldUpdate)
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task {
                await self?.update()
            }
        }
        .store(in: &cancellationTokens)

        Publishers.MergeMany(
            UserPreferences.shared.$showRemindersWithDueDateOnTop.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$sortRemindersByFlagAndPriority.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$reminderSortingOrder.map { _ in }.eraseToAnyPublisher(),
            $calendarIdentifiersFilter.removeDuplicates().map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                await self?.update()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addUpcomingObservers() {
        Publishers.MergeMany(
            UserPreferences.shared.$upcomingRemindersInterval.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$filterUpcomingRemindersByCalendar.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                await self?.reloadDerivedReminders()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addTagObservers() {
        Publishers.MergeMany(
            $tagsFilter.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$filterTagRemindersByCalendar.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                await self?.reloadDerivedReminders()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addMenuBarObservers() {
        Publishers.MergeMany(
            UserPreferences.shared.$menuBarCounterType.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$filterMenuBarContentByCalendar.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$menuBarReminderPreviewEnabled.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                await self?.reloadDerivedReminders()
            }
        }
        .store(in: &cancellationTokens)

        Publishers.MergeMany(
            UserPreferences.shared.$reminderMenuBarIcon.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$hideMenuBarIconWhenContentIsShown.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { _ in
            AppDelegate.shared.loadMenuBarIcon()
        }
        .store(in: &cancellationTokens)
    }

    private func addSearchObservers() {
        $searchText
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .combineLatest($searchableReminders)
            .sink { [weak self] query, cached in
                guard let self else { return }
                guard showingSearch, !query.isEmpty, let cached else {
                    searchResults = nil
                    return
                }
                searchResults = RemindersService.shared.searchReminders(
                    matching: query,
                    in: cached
                )
            }
            .store(in: &cancellationTokens)
    }

    private func addSectionOrderObservers() {
        Publishers.MergeMany(
            UserPreferences.shared.$showTagsBeforeCalendars.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$showUpcomingReminders.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$hideUpcomingRemindersFromLists.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            self?.cachedOrderedSections = nil
        }
        .store(in: &cancellationTokens)
    }

    @Published var availableCalendars: [EKCalendar] = []

    @Published var availableTags: [Tag] = []

    @Published var upcomingReminders: [ReminderItem] = [] {
        didSet { cachedOrderedSections = nil }
    }

    @Published private var filteredCalendarReminderLists: [CalendarReminderList] = [] {
        didSet { cachedOrderedSections = nil }
    }

    @Published private var filteredTagReminderLists: [TagReminderList] = [] {
        didSet { cachedOrderedSections = nil }
    }

    private var cachedOrderedSections: [ReminderListSection]?

    var orderedFilteredSections: [ReminderListSection] {
        if let cachedOrderedSections {
            return cachedOrderedSections
        }
        let sections = makeOrderedFilteredSections()
        cachedOrderedSections = sections
        return sections
    }

    private func makeOrderedFilteredSections() -> [ReminderListSection] {
        let reminderIdsToExclude = upcomingReminderIdsToExcludeFromLists
        let preservesOrder = reminderIdsToExclude.isEmpty
        let calendarSections = filteredCalendarReminderLists.map { list in
            let exclusionResult = ReminderItemTree.excluding(
                reminderIds: reminderIdsToExclude,
                from: list.reminders
            )
            return ReminderListSection.calendar(
                CalendarReminderList(
                    for: list.calendar,
                    with: exclusionResult.reminders,
                    preservesOrder: preservesOrder
                ),
                hiddenUpcomingReminderCount: exclusionResult.excludedCount
            )
        }
        let tagSections = filteredTagReminderLists.map { list in
            let exclusionResult = ReminderItemTree.excluding(
                reminderIds: reminderIdsToExclude,
                from: list.reminders
            )
            return ReminderListSection.tag(
                TagReminderList(
                    for: list.tag,
                    with: exclusionResult.reminders,
                    preservesOrder: preservesOrder
                ),
                hiddenUpcomingReminderCount: exclusionResult.excludedCount
            )
        }

        if UserPreferences.shared.showTagsBeforeCalendars {
            return tagSections + calendarSections
        }
        return calendarSections + tagSections
    }

    private var upcomingReminderIdsToExcludeFromLists: Set<String> {
        guard UserPreferences.shared.showUpcomingReminders,
              UserPreferences.shared.hideUpcomingRemindersFromLists else {
            return []
        }
        return Set(upcomingReminders.map(\.id))
    }

    @Published var recentReminders: [ReminderItem]?

    @Published var showingRecentReminders: Bool = false {
        didSet {
            if showingRecentReminders {
                showingSearch = false
                Task {
                    self.recentReminders = await fetchRecentReminders()
                }
            } else {
                recentReminders = nil
            }
        }
    }

    @Published var showingSearch: Bool = false {
        didSet {
            if showingSearch {
                showingRecentReminders = false
                Task {
                    self.searchableReminders = await RemindersService.shared.fetchAllReminders()
                }
            } else {
                searchText = ""
                searchResults = nil
                searchableReminders = nil
            }
        }
    }

    @Published var searchText: String = ""

    @Published var searchResults: [ReminderItem]?

    @Published private var searchableReminders: [EKReminder]?

    @Published var calendarIdentifiersFilter: [String] = {
        guard let identifiers = UserPreferences.shared.preferredCalendarIdentifiersFilter else {
            // NOTE: On first use it will load all reminder lists.
            let allCalendars = RemindersService.shared.getCalendars()
            return allCalendars.map({ $0.calendarIdentifier })
        }

        return identifiers
    }() {
        didSet {
            UserPreferences.shared.preferredCalendarIdentifiersFilter = calendarIdentifiersFilter
        }
    }

    @Published var tagsFilter: [Tag] = {
        return (UserPreferences.shared.preferredTagsFilter ?? []).map { Tag($0) }
    }() {
        didSet {
            UserPreferences.shared.preferredTagsFilter = tagsFilter.map(\.name)
        }
    }

    @Published var calendarForSaving: EKCalendar? = {
        guard RemindersService.shared.isAuthorized else {
            return nil
        }

        guard let identifier = UserPreferences.shared.preferredCalendarIdentifierForSaving,
              let calendar = RemindersService.shared.getCalendar(withIdentifier: identifier) else {
            return RemindersService.shared.getDefaultCalendar()
        }

        return calendar
    }() {
        didSet {
            let identifier = calendarForSaving?.calendarIdentifier
            UserPreferences.shared.preferredCalendarIdentifierForSaving = identifier
        }
    }

    func update() async {
        // Validate filter — remove stale calendars that no longer exist
        let calendars = RemindersService.shared.getCalendars()
        let calendarsSet = Set(calendars.map({ $0.calendarIdentifier }))
        self.availableCalendars = calendars
        let validCalendarIdentifiers = self.calendarIdentifiersFilter.filter({ calendarsSet.contains($0) })
        // Assignment publishes and writes UserDefaults even when the contents did not change.
        if validCalendarIdentifiers != self.calendarIdentifiersFilter {
            self.calendarIdentifiersFilter = validCalendarIdentifiers
        }
        CalendarParser.updateShared(with: calendars)

        // One full-catalog read feeds the tag index and, when those views are open, recent/search.
        let allReminders = await RemindersService.shared.fetchAllReminders()
        let tags = RemindersService.shared.tags(in: allReminders)
        self.availableTags = tags
        let validTags = self.tagsFilter.filter({ tags.contains($0) })
        if validTags != self.tagsFilter {
            self.tagsFilter = validTags
        }
        TagParser.updateShared(with: tags)

        let scope = requiredIncompleteScope()
        incompleteReminders = await RemindersService.shared.fetchIncompleteReminders(
            calendarIdentifiers: scope.identifiers
        )
        incompleteSnapshotScope = scope
        applyIncompleteSnapshot()

        if showingRecentReminders {
            self.recentReminders = RemindersService.shared.recentReminderItems(from: allReminders)
        }
        if showingSearch {
            self.searchableReminders = allReminders
        }
    }

    private func fetchRecentReminders() async -> [ReminderItem] {
        return await RemindersService.shared.getRecentReminders()
    }

    private func reloadDerivedReminders() async {
        let neededScope = requiredIncompleteScope()
        if let incompleteSnapshotScope, incompleteSnapshotScope.covers(neededScope) {
            applyIncompleteSnapshot()
            return
        }

        incompleteReminders = await RemindersService.shared.fetchIncompleteReminders(
            calendarIdentifiers: neededScope.identifiers
        )
        incompleteSnapshotScope = neededScope
        applyIncompleteSnapshot()
    }

    private func requiredIncompleteScope() -> IncompleteCalendarScope {
        let preferences = UserPreferences.shared
        var needsAllCalendars = !preferences.filterUpcomingRemindersByCalendar

        if !preferences.filterTagRemindersByCalendar && !tagsFilter.isEmpty {
            needsAllCalendars = true
        }

        let menuBarNeedsReminders = preferences.menuBarCounterType != .disabled
            || preferences.menuBarReminderPreviewEnabled
        if menuBarNeedsReminders && !preferences.filterMenuBarContentByCalendar {
            needsAllCalendars = true
        }

        if needsAllCalendars {
            return .all
        }
        return .calendars(Set(calendarIdentifiersFilter))
    }

    private func applyIncompleteSnapshot() {
        let service = RemindersService.shared
        let preferences = UserPreferences.shared
        let upcomingFilter = preferences.filterUpcomingRemindersByCalendar ? calendarIdentifiersFilter : nil
        let menuBarFilter = preferences.filterMenuBarContentByCalendar ? calendarIdentifiersFilter : nil

        filteredCalendarReminderLists = service.calendarReminderLists(
            from: incompleteReminders,
            calendarIdentifiers: calendarIdentifiersFilter
        )

        let upcoming = service.upcomingReminderItems(
            from: incompleteReminders,
            interval: preferences.upcomingRemindersInterval,
            calendarIdentifiers: upcomingFilter
        )
        upcomingReminders = upcoming

        let tagFilter = preferences.filterTagRemindersByCalendar ? calendarIdentifiersFilter : nil
        filteredTagReminderLists = service.tagReminderLists(
            from: incompleteReminders,
            tags: tagsFilter,
            calendarIdentifiers: tagFilter
        )

        updateMenuBarCount(to: menuBarCount(
            from: incompleteReminders,
            upcoming: upcoming,
            upcomingFilter: upcomingFilter,
            menuBarFilter: menuBarFilter,
            preferences: preferences
        ))
        refreshPreview(upcoming: upcoming, upcomingFilter: upcomingFilter, menuBarFilter: menuBarFilter)
    }

    private func menuBarCount(
        from reminders: [EKReminder],
        upcoming: [ReminderItem],
        upcomingFilter: [String]?,
        menuBarFilter: [String]?,
        preferences: UserPreferences
    ) -> Int {
        switch preferences.menuBarCounterType {
        case .disabled:
            return -1
        case .allReminders:
            // Upcoming items are dated only. `.allReminders` includes reminders with no due date.
            return RemindersService.shared.incompleteCount(from: reminders, calendarIdentifiers: menuBarFilter)
        case .due:
            return upcomingCount(
                matching: .due,
                upcoming: upcoming,
                upcomingFilter: upcomingFilter,
                menuBarFilter: menuBarFilter,
                preferences: preferences
            )
        case .today:
            return upcomingCount(
                matching: .today,
                upcoming: upcoming,
                upcomingFilter: upcomingFilter,
                menuBarFilter: menuBarFilter,
                preferences: preferences
            )
        }
    }

    private func upcomingCount(
        matching interval: ReminderInterval,
        upcoming: [ReminderItem],
        upcomingFilter: [String]?,
        menuBarFilter: [String]?,
        preferences: UserPreferences
    ) -> Int {
        if interval == preferences.upcomingRemindersInterval && menuBarFilter == upcomingFilter {
            return upcoming.count
        }
        return RemindersService.shared.upcomingReminderItems(
            from: incompleteReminders,
            interval: interval,
            calendarIdentifiers: menuBarFilter
        ).count
    }

    private func updateMenuBarCount(to count: Int) {
        AppDelegate.shared.updateMenuBarCount(to: count)
    }

    private func refreshPreview(
        upcoming: [ReminderItem],
        upcomingFilter: [String]?,
        menuBarFilter: [String]?
    ) {
        guard UserPreferences.shared.menuBarReminderPreviewEnabled else {
            previewService.refresh(with: [])
            return
        }

        if UserPreferences.shared.upcomingRemindersInterval == .week && menuBarFilter == upcomingFilter {
            previewService.refresh(with: upcoming)
            return
        }

        let weekReminders = RemindersService.shared.upcomingReminderItems(
            from: incompleteReminders,
            interval: .week,
            calendarIdentifiers: menuBarFilter
        )
        previewService.refresh(with: weekReminders)
    }

    func optimisticallyRemove(reminderItem: ReminderItem) {
        let idsToRemove = Set([reminderItem.id] + reminderItem.childReminders.map(\.id))
        incompleteReminders.removeAll { idsToRemove.contains($0.calendarItemIdentifier) }

        filteredCalendarReminderLists = filteredCalendarReminderLists.map { list in
            let filtered = list.reminders.filter { !idsToRemove.contains($0.id) }
            return CalendarReminderList(for: list.calendar, with: filtered)
        }

        filteredTagReminderLists = filteredTagReminderLists.map { list in
            let filtered = list.reminders.filter { !idsToRemove.contains($0.id) }
            return TagReminderList(for: list.tag, with: filtered)
        }

        upcomingReminders = upcomingReminders.filter { !idsToRemove.contains($0.id) }
    }
}

private enum IncompleteCalendarScope: Equatable {
    case all
    case calendars(Set<String>)

    var identifiers: [String]? {
        switch self {
        case .all:
            return nil
        case .calendars(let identifiers):
            return Array(identifiers)
        }
    }

    func covers(_ needed: IncompleteCalendarScope) -> Bool {
        switch (self, needed) {
        case (.all, _):
            return true
        case (.calendars(let loaded), .calendars(let needed)):
            return needed.isSubset(of: loaded)
        case (.calendars, .all):
            return false
        }
    }
}
