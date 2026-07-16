import SwiftUI
import NextStepAcademic

private enum CompactLibraryRoute: Hashable {
    case notebook(UUID)
    case course(CourseID)
    case session(SessionWorkspaceRoute)
}

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var academicModel: AcademicAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedNotebookID: UUID?
    @State private var selectedCourseID: CourseID?
    @State private var courseDetailPath: [SessionWorkspaceRoute] = []
    @State private var compactPath: [CompactLibraryRoute] = []
    @State private var showsNewNotebook = false
    @State private var showsImporter = false
    @State private var renamingNotebook: LibraryNotebook?
    @State private var sharedPackageURL: URL?
    @State private var showsPackageShare = false
    @State private var hasFinishedInitialLoad = false

    private var selectedNotebook: LibraryNotebook? {
        guard let selectedNotebookID else { return nil }
        return appModel.notebooks.first { $0.id == selectedNotebookID }
    }

    var body: some View {
        libraryNavigation
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet { title, kind, template in
                Task {
                    if let created = await appModel.createNotebook(
                        title: title,
                        kind: kind,
                        template: template
                    ) {
                        appModel.destination = .documents
                        openNotebook(created)
                    }
                }
            }
        }
        .sheet(isPresented: $showsImporter) {
            DocumentPicker(mode: .importableDocuments) { urls in
                showsImporter = false
                Task {
                    let imported = await appModel.importDocuments(urls)
                    if let first = imported.first {
                        appModel.destination = .documents
                        openNotebook(first)
                    }
                }
            } onCancel: {
                showsImporter = false
            }
        }
        .sheet(item: $renamingNotebook) { notebook in
            RenameNotebookSheet(notebook: notebook) { title in
                Task { await appModel.rename(notebook, to: title) }
            }
        }
        .sheet(isPresented: $showsPackageShare) {
            if let sharedPackageURL {
                ActivitySheet(items: [sharedPackageURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .alert(item: $appModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            await appModel.load()
            hasFinishedInitialLoad = true
        }
        .task {
            await academicModel.load()
        }
        .onOpenURL { url in
            Task {
                let imported = await appModel.importDocuments([url])
                if let first = imported.first {
                    appModel.destination = .documents
                    openNotebook(first)
                }
            }
        }
        .onChange(of: appModel.destination) { _, destination in
            if destination == .courses {
                selectedNotebookID = nil
                return
            }
            selectedCourseID = nil
            courseDetailPath.removeAll()
            guard destination != .settings else {
                selectedNotebookID = nil
                return
            }
            if let selectedNotebookID,
               !appModel.visibleNotebooks.contains(where: { $0.id == selectedNotebookID }) {
                self.selectedNotebookID = nil
            }
        }
        .onChange(of: selectedCourseID) { _, _ in
            courseDetailPath.removeAll()
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            migrateNavigation(to: sizeClass)
        }
    }

    @ViewBuilder
    private var libraryNavigation: some View {
        if horizontalSizeClass == .compact {
            compactLibraryNavigation
        } else {
            regularLibraryNavigation
        }
    }

    private var regularLibraryNavigation: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 310)
        } content: {
            if appModel.destination == .courses {
                CourseListView(selectedCourseID: $selectedCourseID)
            } else if appModel.destination == .settings {
                SettingsView()
            } else {
                libraryContent
            }
        } detail: {
            if appModel.destination == .courses {
                courseDetail
            } else if let selectedNotebook, selectedNotebook.deletedAt == nil {
                NotebookEditorView(
                    notebookSummary: selectedNotebook,
                    initialPageID: appModel.searchTargetPageIDs[selectedNotebook.id]
                )
                    .id(selectedNotebook.id)
            } else {
                emptyLibraryDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactLibraryNavigation: some View {
        NavigationStack(path: $compactPath) {
            Group {
                if appModel.destination == .courses {
                    CourseListView(
                        selectedCourseID: $selectedCourseID,
                        onOpenCourse: openCourse
                    )
                } else if appModel.destination == .settings {
                    SettingsView()
                } else {
                    libraryContent
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    compactDestinationMenu
                }
            }
            .navigationDestination(for: CompactLibraryRoute.self) { route in
                compactDestination(for: route)
            }
        }
    }

    private var compactDestinationMenu: some View {
        Menu {
            ForEach(LibraryDestination.allCases) { destination in
                Button {
                    selectCompactDestination(destination)
                } label: {
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.symbolName)
                    }
                }
                .accessibilityIdentifier("library.\(destination.rawValue)")
            }
        } label: {
            Label {
                Text(appModel.destination.title)
            } icon: {
                Image(systemName: "line.3.horizontal")
            }
        }
        .accessibilityLabel(Text("Library"))
        .accessibilityIdentifier("library.destination.menu")
    }

    @ViewBuilder
    private func compactDestination(for route: CompactLibraryRoute) -> some View {
        switch route {
        case .notebook(let notebookID):
            if let notebook = appModel.notebooks.first(where: { $0.id == notebookID }),
               notebook.deletedAt == nil {
                NotebookEditorView(
                    notebookSummary: notebook,
                    initialPageID: appModel.searchTargetPageIDs[notebook.id]
                )
                .id(notebook.id)
            } else {
                ContentUnavailableView {
                    Label("Choose a note", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text("Select a note from your library or create a new one.")
                }
            }

        case .course(let courseID):
            CourseDetailView(courseID: courseID) { route in
                compactPath.append(.session(route))
            }

        case .session(let route):
            SessionWorkspaceView(route: route)
        }
    }

    private var emptyLibraryDetail: some View {
        ContentUnavailableView {
            Label("Choose a note", systemImage: "square.and.pencil")
        } description: {
            Text("Select a note from your library or create a new one.")
        }
    }

    private func selectCompactDestination(_ destination: LibraryDestination) {
        compactPath.removeAll()
        selectedNotebookID = nil
        selectedCourseID = nil
        courseDetailPath.removeAll()
        appModel.destination = destination
    }

    private func migrateNavigation(to sizeClass: UserInterfaceSizeClass?) {
        guard sizeClass == .compact else {
            if let route = compactPath.last,
               case .session(let sessionRoute) = route {
                courseDetailPath = [sessionRoute]
            }
            compactPath.removeAll()
            return
        }

        if appModel.destination == .courses,
           let selectedCourseID {
            var path: [CompactLibraryRoute] = [.course(selectedCourseID)]
            if let sessionRoute = courseDetailPath.last {
                path.append(.session(sessionRoute))
            }
            compactPath = path
        } else if let selectedNotebook,
                  selectedNotebook.deletedAt == nil {
            compactPath = [.notebook(selectedNotebook.id)]
        } else {
            compactPath.removeAll()
        }
    }

    private func openCourse(_ courseID: CourseID) {
        selectedCourseID = courseID
        compactPath = [.course(courseID)]
    }

    @ViewBuilder
    private var courseDetail: some View {
        NavigationStack(path: $courseDetailPath) {
            Group {
                if let selectedCourseID {
                    CourseDetailView(courseID: selectedCourseID) { route in
                        courseDetailPath = [route]
                    }
                } else {
                    ContentUnavailableView {
                        Label("Choose a course", systemImage: "book.closed")
                    } description: {
                        Text("Select a course to view its schedule and class sessions.")
                    }
                    .accessibilityIdentifier("courses.detail.empty")
                }
            }
            .navigationDestination(for: SessionWorkspaceRoute.self) { route in
                SessionWorkspaceView(route: route)
            }
        }
    }

    private var sidebar: some View {
        List(selection: destinationSelection) {
            Section {
                ForEach(LibraryDestination.allCases) { destination in
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.symbolName)
                    }
                        .tag(destination)
                        .accessibilityIdentifier("library.\(destination.rawValue)")
                }
            } header: {
                Text("Library")
            }
        }
        .navigationTitle("NextStep")
        .accessibilityIdentifier("library.sidebar")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    showsNewNotebook = true
                } label: {
                    Label("New notebook", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.new")
                .disabled(!libraryActionsAreReady)

                Button {
                    Task {
                        if let quickNote = await appModel.createQuickNote() {
                            appModel.destination = .documents
                            selectedNotebookID = quickNote.id
                        }
                    }
                } label: {
                    Label("Quick Note", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.quickNote")
                .disabled(!libraryActionsAreReady)
            }
            .padding()
            .background(.bar)
        }
    }

    private var destinationSelection: Binding<LibraryDestination?> {
        Binding(
            get: { appModel.destination },
            set: { destination in
                if let destination { appModel.destination = destination }
            }
        )
    }

    private var libraryActionsAreReady: Bool {
        hasFinishedInitialLoad && !appModel.isLoading
    }

    private var libraryContent: some View {
        Group {
            if appModel.isLoading {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.visibleNotebooks.isEmpty {
                emptyState
            } else if appModel.displayMode == .grid {
                grid
            } else {
                list
            }
        }
        .navigationTitle(Text(appModel.destination.title))
        .searchable(text: $appModel.searchText, prompt: Text("Search notes"))
        .task(id: appModel.searchText) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await appModel.searchIndexedContent()
        }
        .onSubmit(of: .search) {
            Task { await appModel.searchIndexedContent() }
        }
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .topBarTrailing) {
                    compactLibraryActionsMenu
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        sortPicker
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }

                    Picker("View", selection: $appModel.displayMode) {
                        Image(systemName: "square.grid.2x2").tag(LibraryDisplayMode.grid)
                        Image(systemName: "list.bullet").tag(LibraryDisplayMode.list)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 92)

                    addNotebookMenu
                }
            }
        }
    }

    private var compactLibraryActionsMenu: some View {
        Menu {
            Menu {
                sortPicker
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Picker("View", selection: $appModel.displayMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryDisplayMode.grid)
                Image(systemName: "list.bullet").tag(LibraryDisplayMode.list)
            }

            Divider()
            addNotebookMenuContent
        } label: {
            Label("Library", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("library.actions.menu")
    }

    private var addNotebookMenu: some View {
        Menu {
            addNotebookMenuContent
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    @ViewBuilder
    private var addNotebookMenuContent: some View {
        Button {
            showsNewNotebook = true
        } label: {
            Label("New notebook", systemImage: "book.closed")
        }
        .disabled(!libraryActionsAreReady)

        Button {
            Task {
                if let quickNote = await appModel.createQuickNote() {
                    appModel.destination = .documents
                    openNotebook(quickNote)
                }
            }
        } label: {
            Label("Quick Note", systemImage: "bolt.fill")
        }
        .disabled(!libraryActionsAreReady)

        Divider()
        Button {
            showsImporter = true
        } label: {
            Label("Import file", systemImage: "square.and.arrow.down")
        }
    }

    @ViewBuilder
    private var sortPicker: some View {
        Picker("Sort by", selection: $appModel.sortOrder) {
            ForEach(LibrarySortOrder.allCases) { order in
                Text(order.title).tag(order)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: horizontalSizeClass == .compact ? 150 : 168,
                        maximum: horizontalSizeClass == .compact ? 190 : 230
                    ),
                    spacing: horizontalSizeClass == .compact ? 14 : 20
                )],
                spacing: horizontalSizeClass == .compact ? 18 : 24
            ) {
                ForEach(appModel.visibleNotebooks) { notebook in
                    Button {
                        openNotebook(notebook)
                    } label: {
                        NotebookGridCard(notebook: notebook, isSelected: notebook.id == selectedNotebookID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { notebookActions(notebook) }
                    .accessibilityIdentifier("notebook.\(notebook.id.uuidString)")
                }
            }
            .padding(horizontalSizeClass == .compact ? 16 : 24)
        }
        .accessibilityIdentifier("library.grid")
    }

    private var list: some View {
        List(selection: $selectedNotebookID) {
            ForEach(appModel.visibleNotebooks) { notebook in
                if horizontalSizeClass == .compact {
                    Button {
                        openNotebook(notebook)
                    } label: {
                        NotebookListRow(notebook: notebook)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { notebookActions(notebook) }
                    .accessibilityIdentifier("notebook.\(notebook.id.uuidString)")
                } else {
                    NotebookListRow(notebook: notebook)
                        .tag(notebook.id)
                        .contextMenu { notebookActions(notebook) }
                }
            }
        }
        .accessibilityIdentifier("library.list")
    }

    private func openNotebook(_ notebook: LibraryNotebook) {
        selectedNotebookID = notebook.id
        guard horizontalSizeClass == .compact,
              notebook.deletedAt == nil else { return }
        compactPath = [.notebook(notebook.id)]
    }

    @ViewBuilder
    private func notebookActions(_ notebook: LibraryNotebook) -> some View {
        if appModel.destination == .trash {
            Button {
                Task { await appModel.restore(notebook) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                Task {
                    await appModel.deletePermanently(notebook)
                    if selectedNotebookID == notebook.id { selectedNotebookID = nil }
                }
            } label: {
                Label("Delete permanently", systemImage: "trash.slash")
            }
        } else {
            Button {
                Task {
                    guard let url = await appModel.packageURL(for: notebook) else { return }
                    sharedPackageURL = url
                    showsPackageShare = true
                }
            } label: {
                Label("Share notebook", systemImage: "square.and.arrow.up")
            }
            Button {
                renamingNotebook = notebook
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                Task { await appModel.toggleFavorite(notebook) }
            } label: {
                Label(
                    notebook.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: notebook.isFavorite ? "star.slash" : "star"
                )
            }
            Button(role: .destructive) {
                Task {
                    await appModel.moveToTrash(notebook)
                    if selectedNotebookID == notebook.id { selectedNotebookID = nil }
                }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(emptyTitle)
            } icon: {
                Image(systemName: emptySymbol)
            }
        } description: {
            Text(emptyDescription)
        } actions: {
            if appModel.destination == .documents {
                Button("Create a notebook") {
                    showsNewNotebook = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!libraryActionsAreReady)
            }
        }
    }

    private var emptyTitle: LocalizedStringResource {
        switch appModel.destination {
        case .courses: "Courses"
        case .documents: "No notes yet"
        case .favorites: "No favorites yet"
        case .trash: "Trash is empty"
        case .settings: "Settings"
        }
    }

    private var emptyDescription: LocalizedStringResource {
        switch appModel.destination {
        case .courses: "Create a course to organize its class sessions and notes."
        case .documents: "Create a notebook, start a Quick Note, or import a document."
        case .favorites: "Favorite notes appear here for quick access."
        case .trash: "Deleted notes remain here until you remove them permanently."
        case .settings: ""
        }
    }

    private var emptySymbol: String {
        switch appModel.destination {
        case .courses: "books.vertical"
        case .documents: "square.and.pencil"
        case .favorites: "star"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }
}

private struct RenameNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    let notebook: LibraryNotebook
    let onRename: (String) -> Void
    @State private var title: String
    @FocusState private var titleFocused: Bool

    init(notebook: LibraryNotebook, onRename: @escaping (String) -> Void) {
        self.notebook = notebook
        self.onRename = onRename
        _title = State(initialValue: notebook.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .focused($titleFocused)
            }
            .navigationTitle("Rename note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        onRename(title.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium])
    }
}

private struct NotebookGridCard: View {
    let notebook: LibraryNotebook
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: notebook.coverHue, saturation: 0.55, brightness: 0.92),
                                Color(hue: notebook.coverHue, saturation: 0.72, brightness: 0.68)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(0.78, contentMode: .fit)
                    .overlay {
                        Image(systemName: notebook.kind.symbolName)
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.black.opacity(0.12))
                            .frame(width: 9)
                            .padding(.vertical, 8)
                    }

                if notebook.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(10)
                        .accessibilityLabel("Favorite")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.09), radius: 8, y: 4)

            Text(notebook.title)
                .font(.headline)
                .lineLimit(1)
            ViewThatFits(in: .horizontal) {
                HStack {
                    pageCount
                    Spacer()
                    modifiedDate
                }
                VStack(alignment: .leading, spacing: 2) {
                    pageCount
                    modifiedDate
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var pageCount: some View {
        HStack(spacing: 3) {
            Text(verbatim: "\(notebook.pageCount)")
            Text("page count suffix")
        }
    }

    private var modifiedDate: some View {
        Text(notebook.modifiedAt, format: .relative(presentation: .named))
    }
}

private struct NotebookListRow: View {
    let notebook: LibraryNotebook

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hue: notebook.coverHue, saturation: 0.58, brightness: 0.84))
                .frame(width: 42, height: 54)
                .overlay {
                    Image(systemName: notebook.kind.symbolName)
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notebook.title)
                        .font(.headline)
                    if notebook.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        pageCount
                        Text(verbatim: "•")
                        modifiedDate
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        pageCount
                        modifiedDate
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var pageCount: some View {
        HStack(spacing: 3) {
            Text(verbatim: "\(notebook.pageCount)")
            Text("page count suffix")
        }
    }

    private var modifiedDate: some View {
        Text(notebook.modifiedAt, format: .relative(presentation: .named))
    }
}

private struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleIsFocused: Bool
    @State private var title = ""
    @State private var kind: NotebookKind = .notebook
    @State private var template: PaperTemplate = .blank
    let onCreate: (String, NotebookKind, PaperTemplate) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    HStack {
                        TextField("Title", text: $title)
                            .focused($titleIsFocused)
                            .submitLabel(.done)
                            .onSubmit { titleIsFocused = false }
                            .accessibilityIdentifier("newNotebook.title")

                        if titleIsFocused {
                            Button("Done") { titleIsFocused = false }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("newNotebook.title.done")
                        }
                    }
                }

                Section("Type") {
                    ForEach(NotebookKind.creatableKinds) { noteKind in
                        Button {
                            kind = noteKind
                        } label: {
                            HStack {
                                Label {
                                    Text(noteKind.title)
                                } icon: {
                                    Image(systemName: noteKind.symbolName)
                                }
                                Spacer()
                                if kind == noteKind {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newNotebook.kind.\(noteKind.rawValue)")
                        .accessibilityLabel(Text(noteKind.title))
                        .accessibilityAddTraits(kind == noteKind ? .isSelected : [])
                    }
                }

                if kind == .notebook {
                    Section("Paper") {
                        Picker("Template", selection: $template) {
                            ForEach(PaperTemplate.allCases) { paper in
                                Label {
                                    Text(paper.title)
                                } icon: {
                                    Image(systemName: paper.symbolName)
                                }
                                .tag(paper)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
            .accessibilityIdentifier("newNotebook.form")
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title, kind, template)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("newNotebook.create")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
