import SaySoCore
import SwiftUI

/// Diccionario personal del dictado: palabras que se escriben así y sustituciones fijas.
struct DictionaryPanel: View {
    let model: AppModel
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    private var settings: DictationSettings { model.dictation }

    private func update(_ change: (inout DictationSettings) -> Void) {
        var s = model.dictation
        change(&s)
        model.actions?.updateDictation(s)
    }

    private func addWords() {
        // Se pueden pegar varias separadas por comas.
        let words = newWord.split(separator: ",").map { String($0) }
        update { $0.vocabulary = DictationVocabulary.clean($0.vocabulary + words) }
        newWord = ""
    }

    private var canAddReplacement: Bool {
        !newFrom.trimmingCharacters(in: .whitespaces).isEmpty
            && settings.replacements.count < DictationVocabulary.maxReplacements
    }

    private func addReplacement() {
        guard canAddReplacement else { return }
        let from = newFrom.trimmingCharacters(in: .whitespaces)
        update { s in
            s.replacements.removeAll { $0.id == from.lowercased() }
            s.replacements.append(TextReplacement(from: from, to: newTo.trimmingCharacters(in: .whitespaces)))
        }
        newFrom = ""
        newTo = ""
    }

    var body: some View {
        Panel {
            HStack(spacing: Theme.Space.m) {
                PanelLabel("Diccionario")
                Spacer()
                Text(tr("%@ palabras · %@ sustituciones", "\(settings.vocabulary.count)", "\(settings.replacements.count)"))
                    .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
            }
            Text(tr("Nombres, marcas y siglas que quieres ver escritos siempre igual. Se le dan como pista al reconocimiento de voz y a la corrección con IA, y se ajustan sus mayúsculas."))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !settings.vocabulary.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(settings.vocabulary, id: \.self) { word in chip(word) }
                }
            }
            HStack(spacing: Theme.Space.s) {
                BlockField("Pepebits, SaySo, Anna…", text: $newWord, label: "Palabra nueva para el diccionario")
                    .onSubmit(addWords)
                BlockButton("Añadir", systemImage: "plus", compact: true, action: addWords)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty
                              || settings.vocabulary.count >= DictationVocabulary.maxWords)
            }

            CardDivider()
            Text(tr("Sustituciones")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
            Text(tr("Cambian una palabra o frase dictada por otra: «arroba» por «@», «firma» por tu firma completa."))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(settings.replacements) { replacement in
                HStack(spacing: Theme.Space.s) {
                    Text(verbatim: replacement.from).font(Theme.mono(12.5)).foregroundStyle(Theme.ink)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.secondary).accessibilityHidden(true)
                    Text(verbatim: replacement.to.isEmpty ? tr("(nada)") : replacement.to)
                        .font(Theme.mono(12.5)).foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Space.s)
                    BlockButton("Quitar", kind: .destructive, compact: true) {
                        update { $0.replacements.removeAll { $0.id == replacement.id } }
                    }
                    .accessibilityLabel(tr("Quitar la sustitución de «%@»", replacement.from))
                }
                .accessibilityElement(children: .contain)
            }
            HStack(spacing: Theme.Space.s) {
                BlockField("Lo que dices", text: $newFrom, label: "Palabra o frase dictada")
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.secondary).accessibilityHidden(true)
                BlockField("Lo que se escribe", text: $newTo, label: "Texto que la sustituye")
                    .onSubmit(addReplacement)
                BlockButton("Añadir", systemImage: "plus", compact: true, action: addReplacement)
                    .disabled(!canAddReplacement)
                    .accessibilityLabel("Añadir sustitución")
            }
        }
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: word).font(Theme.bodyStrong).lineLimit(1)
            Button {
                update { $0.vocabulary.removeAll { $0 == word } }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Quitar «%@» del diccionario", word))
        }
        .foregroundStyle(Theme.paper)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .contain)
    }
}
