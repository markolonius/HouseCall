//
//  ContentView.swift
//  HouseCall
//
//  DEPRECATED: Template view from Xcode project creation
//  Replaced by authentication-based navigation in HouseCallApp.swift
//  Kept for reference during development
//

import SwiftUI
import CoreData

/// Template ContentView from Xcode project template
/// - Note: This view is deprecated and not used in the app flow
/// - See: HouseCallApp.swift for actual app navigation (LoginView -> MainAppView)
struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var errorMessage: String?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.timestamp, ascending: true)],
        animation: .default)
    private var items: FetchedResults<Item>

    var body: some View {
        NavigationView {
            VStack {
                if let error = errorMessage {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .padding()
                }

                List {
                    ForEach(items) { item in
                        NavigationLink {
                            Text("Item at \(item.timestamp!, formatter: itemFormatter)")
                        } label: {
                            Text(item.timestamp!, formatter: itemFormatter)
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                    ToolbarItem {
                        Button(action: addItem) {
                            Label("Add Item", systemImage: "plus")
                        }
                    }
                }
            }
            Text("Select an item")
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()

            do {
                try viewContext.save()
                errorMessage = nil
            } catch {
                // Proper error handling - no fatalError
                let nsError = error as NSError
                print("❌ Failed to save item: \(nsError.localizedDescription)")

                // Display error to user
                errorMessage = "Failed to save item: \(nsError.localizedDescription)"

                // Rollback changes
                viewContext.rollback()

                // Log to audit trail
                try? AuditLogger.shared.log(
                    event: .dataModified,
                    userId: nil,
                    message: "Failed to save item: \(nsError.localizedDescription)"
                )
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { items[$0] }.forEach(viewContext.delete)

            do {
                try viewContext.save()
                errorMessage = nil
            } catch {
                // Proper error handling - no fatalError
                let nsError = error as NSError
                print("❌ Failed to delete items: \(nsError.localizedDescription)")

                // Display error to user
                errorMessage = "Failed to delete items: \(nsError.localizedDescription)"

                // Rollback changes
                viewContext.rollback()

                // Log to audit trail
                try? AuditLogger.shared.log(
                    event: .dataDeleted,
                    userId: nil,
                    message: "Failed to delete items: \(nsError.localizedDescription)"
                )
            }
        }
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
