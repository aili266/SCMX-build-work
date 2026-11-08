import SwiftUI

struct RegisterView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var debug: DebugSession
    @State private var snapshot: RegisterSnapshot?
    @State private var profileID = ""
    @State private var loadedDeviceKey = ""
    @State private var category = ""
    @State private var instance = ""
    @State private var filter = ""
    @State private var loading = false
    @State private var loadError = ""
    @State private var lastReadID = ""
    @State private var pendingRead: RegisterDefinition?
    @State private var showReadWarning = false

    private var choices: [RegisterProfileChoice] { RegisterCatalog.choices(family:studio.settings.chipFamily,model:studio.settings.chipModel) }
    private var effectiveProfileID: String { choices.first(where:{$0.id == profileID})?.id ?? choices.first?.id ?? "" }
    private var selectionKey: String { studio.settings.chipFamily + "|" + studio.settings.chipModel + "|" + effectiveProfileID }
    private var definitions: [RegisterDefinition] { snapshot?.model == studio.settings.chipModel && snapshot?.profile.id == effectiveProfileID ? snapshot?.registers ?? [] : [] }
    private var categories: [String] { Array(Set(definitions.map(\.peripheral))).sorted() }
    private var groupRows: [RegisterDefinition] { definitions.filter { category.isEmpty || $0.peripheral == category } }
    private var instances: [String] { Array(Set(groupRows.map(\.instance))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var rows: [RegisterDefinition] {
        groupRows.filter { (instance.isEmpty || $0.instance == instance) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.purpose.localizedCaseInsensitiveContains(filter) || $0.address.localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Card(title:"Device Registers",icon:"list.bullet.rectangle") {
                    DeviceSelectionView(studio:studio)
                    if choices.count > 1 {
                        Picker("Core / Register Profile",selection:Binding(get:{effectiveProfileID},set:{profileID = $0})) {
                            ForEach(choices) { choice in Text(choice.core.isEmpty ? choice.id : choice.core).tag(choice.id) }
                        }
                        Text("Multi-profile devices support definition browsing only; live register reads are not enabled.").font(.caption).foregroundStyle(.orange)
                    }
                    if let snapshot, snapshot.model == studio.settings.chipModel, snapshot.profile.id == effectiveProfileID {
                        HStack {
                            Text("SVD profile: \(snapshot.profile.name)").font(.caption).textSelection(.enabled)
                            Spacer()
                            Text(L10n.format("%lld registers",snapshot.registers.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Vendor profiles may be shared by several part numbers. Check optional blocks and package pins in the device manual.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Peripheral",selection:$category) {
                                Text("All Peripherals").tag("")
                                ForEach(categories,id:\.self) { Text($0).tag($0) }
                            }.frame(maxWidth:230).onChange(of:category) { _ in instance = "" }
                            Picker("Instance",selection:$instance) {
                                Text("All Instances").tag("")
                                ForEach(instances,id:\.self) { Text($0).tag($0) }
                            }.frame(maxWidth:230)
                            TextField("Search registers / address",text:$filter).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                if studio.settings.chipModel.isEmpty {
                    Label("No device selected",systemImage:"cpu").foregroundStyle(.secondary)
                } else if loading {
                    ProgressView("Loading register definitions…")
                } else if !loadError.isEmpty {
                    Label(loadError,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    HStack {
                        Text(L10n.format("%lld registers",rows.count)).font(.headline)
                        Spacer()
                        Text("Reads can change hardware flags.").font(.caption).foregroundStyle(.secondary)
                    }
                    if rows.isEmpty { Text("No matching registers").foregroundStyle(.secondary) }
                    LazyVStack(spacing:0) {
                        ForEach(rows) { register in
                            registerRow(register)
                            Divider()
                        }
                    }
                }
            }.padding(24)
        }
        .task(id:selectionKey) { await loadDefinitions() }
        .alert("Read a Register with Side Effects?",isPresented:$showReadWarning) {
            Button("Cancel",role:.cancel) { pendingRead = nil }
            Button("Read Once") { if let register = pendingRead { read(register) }; pendingRead = nil }
        } message: { Text("The vendor definition marks this read as changing hardware state. It may clear flags or affect a peripheral.") }
    }

    private func registerRow(_ register:RegisterDefinition) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading,spacing:4) {
                    Text(register.name).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                    Text(register.address + " · " + L10n.format("%lld-bit",register.size) + " · " + L10n.string(register.access.isEmpty ? "Access unspecified" : register.access)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(register.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    if register.readAction != nil { Label("Read side effect",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength:12)
                Button {
                    if register.readAction != nil { pendingRead = register; showReadWarning = true }
                    else { read(register) }
                } label: { Image(systemName:"arrow.clockwise") }
                    .help("Read Register").accessibilityLabel("Read Register")
                    .disabled(!register.canRead || !debug.connected || debug.running || debug.deviceModel != studio.settings.chipModel || debug.registerProfileID != register.profileID)
            }
            if lastReadID == register.id {
                Text(debug.registerResultID == register.resultID ? debug.registerOutput : L10n.string("Reading…"))
                    .font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
    }

    private func read(_ register:RegisterDefinition) {
        guard register.model == studio.settings.chipModel else { return }
        lastReadID = register.id; debug.readRegister(register)
    }

    @MainActor private func loadDefinitions() async {
        let family = studio.settings.chipFamily, model = studio.settings.chipModel, requested = effectiveProfileID
        lastReadID = ""; loadError = ""
        let deviceKey = family + "|" + model
        if loadedDeviceKey != deviceKey {
            snapshot = nil; instance = ""; filter = ""; loadedDeviceKey = deviceKey
        }
        guard !model.isEmpty, !family.isEmpty else { snapshot = nil; loading = false; return }
        loading = true
        do {
            let loaded = try await Task.detached(priority:.userInitiated) { try RegisterCatalog.snapshot(family:family,model:model,profileID:requested) }.value
            guard !Task.isCancelled else { return }
            snapshot = loaded
            if !categories.contains(category) { category = categories.contains("GPIO") ? "GPIO" : categories.first ?? "" }
            if !instances.contains(instance) { instance = "" }
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil; loading = false; loadError = error.localizedDescription
        }
    }
}
