import SwiftUI
import UIKit

/// The recipe card of one photo: the film simulation and every setting the camera recorded, then the shot.
struct RecipeCard: View {
    let url: URL
    @State private var recipe: Recipe?
    @State private var shot = ShotInfo()
    @State private var loaded = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    private let library = RecipeLibrary.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let recipe {
                        RecipeSheet(recipe: recipe)
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = recipe.text
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy recipe", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(PillStyle(filled: true))
                            Button { library.toggle(recipe) } label: {
                                Label(library.isSaved(recipe) ? "In library" : "Save", systemImage: library.isSaved(recipe) ? "bookmark.fill" : "bookmark")
                            }
                            .buttonStyle(PillStyle(filled: false))
                            ShareLink(item: recipe.text) { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(PillStyle(filled: false))
                        }
                    } else if loaded {
                        Text("No Fujifilm recipe in this file.").font(Ink.prose(15)).foregroundStyle(Ink.ink2)
                    } else {
                        ProgressView()
                    }
                    if !shot.rows.isEmpty {
                        RecipeRows(title: "Shot", rows: shot.rows)
                    }
                }
                .padding(22)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Ink.paper)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: url) {
            let read = await Task.detached(priority: .userInitiated) { RecipeReader.read(url) }.value
            recipe = read.recipe
            shot = read.shot
            loaded = true
        }
    }
}

/// The film simulation as a title, then the settings, two columns wide where there is room.
struct RecipeSheet: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Film simulation").font(Ink.side(.detail)).foregroundStyle(Ink.muted)
                Text(recipe.film).font(Ink.serif(30, .medium)).foregroundStyle(Ink.ink)
            }
            RecipeRows(title: nil, rows: Array(recipe.rows.dropFirst()))
        }
    }
}

struct RecipeRows: View {
    let title: String?
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(Ink.side(.header)).foregroundStyle(Ink.ink2)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).font(Ink.side(.title)).foregroundStyle(Ink.ink2)
                        Spacer(minLength: 12)
                        Text(row.1).font(Ink.side(.title, .semibold)).foregroundStyle(Ink.ink).monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < rows.count - 1 {
                        Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        }
    }
}

/// Capsule buttons for sheets: filled for the main action, outlined for the rest.
struct PillStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.side(.title, .semibold))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .foregroundStyle(filled ? Ink.paper : Ink.ink)
            .background(filled ? Ink.ink : Ink.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? .clear : Ink.rule, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Recipes: the ones kept, and every recipe found in the imported photos, most used first.
struct RecipesPage: View {
    let model: BenchModel
    private let library = RecipeLibrary.shared
    @State private var open: RecipeLibrary.Found?
    @State private var openSaved: Recipe?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recipes").font(Ink.serif(30, .medium)).foregroundStyle(Ink.ink)
                    Text("Every Fujifilm JPEG carries the settings that made it. Fuji Bridge reads them from your imported photos; keep the ones you like, copy them, share them.")
                        .font(Ink.prose(15)).foregroundStyle(Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !library.saved.isEmpty {
                    section("Saved") {
                        ForEach(library.saved) { recipe in
                            Button { openSaved = recipe } label: { row(recipe, detail: nil, sample: nil) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                section("In your photos") {
                    if library.scanning && library.found.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text("Reading your photos…").font(Ink.side(.detail)).foregroundStyle(Ink.ink2) }
                    } else if library.found.isEmpty {
                        Text(model.saved.isEmpty ? "Import some photos first." : "No Fujifilm recipes found in the imported photos.")
                            .font(Ink.side(.detail)).foregroundStyle(Ink.ink2)
                    }
                    ForEach(library.found) { found in
                        Button { open = found } label: {
                            row(found.recipe, detail: "\(found.count) photo\(found.count == 1 ? "" : "s")", sample: found.sample)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .task(id: model.saved.count) { await library.scan(model.saved) }
        .sheet(item: $open) { found in RecipeCard(url: found.sample) }
        .sheet(item: $openSaved) { recipe in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        RecipeSheet(recipe: recipe)
                        HStack(spacing: 10) {
                            Button { UIPasteboard.general.string = recipe.text } label: { Label("Copy recipe", systemImage: "doc.on.doc") }
                                .buttonStyle(PillStyle(filled: true))
                            Button(role: .destructive) { library.toggle(recipe); openSaved = nil } label: { Label("Remove", systemImage: "bookmark.slash") }
                                .buttonStyle(PillStyle(filled: false))
                        }
                    }
                    .padding(22)
                }
                .background(Ink.paper)
                .navigationTitle("Recipe")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Ink.side(.header)).foregroundStyle(Ink.ink2)
            content()
        }
    }

    private func row(_ recipe: Recipe, detail: String?, sample: URL?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let sample { SampleThumb(url: sample) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recipe.film).font(Ink.side(.name)).foregroundStyle(Ink.ink)
                    if library.isSaved(recipe) { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Ink.ink2) }
                }
                Text(recipe.rows.dropFirst().prefix(6).map { "\($0.0) \($0.1)" }.joined(separator: " · "))
                    .font(Ink.side(.detail)).foregroundStyle(Ink.ink2).lineLimit(2)
                if let detail { Text(detail).font(Ink.side(.detail)).foregroundStyle(Ink.muted) }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.muted)
        }
        .padding(12)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

private struct SampleThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Ink.surface2
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) { image = await Thumbnails.shared.image(for: url) }
    }
}
