import Foundation
import Testing
@testable import ReachlyAgent

@Suite("Caimex model choices")
struct CaimexModelChoicesTests {
    @Test func keepsTheCatalogueOrder() {
        let models = [
            CaimexModel(id: "alpha", featured: true),
            CaimexModel(id: "beta"),
            CaimexModel(id: "caimex/auto"),
        ]

        let choices = CaimexModelChoices(models: models, current: "beta")

        #expect(choices.ids == ["alpha", "beta", "caimex/auto"])
    }

    @Test func keepsASavedModelTheListNoLongerHas() {
        let choices = CaimexModelChoices(models: [CaimexModel(id: "alpha")], current: "old-model")

        #expect(choices.ids == ["old-model", "alpha"], "the user's model stays selectable")
    }

    @Test func doesNotDuplicateASavedModelTheListHas() {
        let models = [CaimexModel(id: "alpha"), CaimexModel(id: "beta")]

        let choices = CaimexModelChoices(models: models, current: "alpha")

        #expect(choices.ids == ["alpha", "beta"])
    }

    @Test func anEmptySavedModelAddsNothing() {
        let choices = CaimexModelChoices(models: [CaimexModel(id: "alpha")], current: "")

        #expect(choices.ids == ["alpha"])
    }

    @Test func anEmptyListStillOffersTheSavedModel() {
        let choices = CaimexModelChoices(models: [], current: "deepseek-v4-flash")

        #expect(choices.ids == ["deepseek-v4-flash"])
    }

    @Test func keepsOpaqueIdsWhole() {
        let models = [CaimexModel(id: "ollama/qwen3-vl:8b")]

        let choices = CaimexModelChoices(models: models, current: "ollama/qwen3-vl:8b")
        let missing = CaimexModelChoices(models: [], current: "caimex/auto")

        #expect(choices.ids == ["ollama/qwen3-vl:8b"])
        #expect(missing.ids == ["caimex/auto"])
    }

    @Test func leavesOutModelsThatCannotCallTools() {
        let models = [
            CaimexModel(id: "tools", supportsTools: true),
            CaimexModel(id: "no-tools", supportsTools: false),
            CaimexModel(id: "unknown"),
        ]
        let choices = CaimexModelChoices(models: models, current: "tools")
        #expect(choices.ids == ["tools", "unknown"], "a model the gateway didn't describe stays")
        #expect(choices.withoutToolsCount == 1)
    }

    @Test func keepsTheCurrentModelEvenWhenItCannotCallTools() {
        let models = [CaimexModel(id: "tools", supportsTools: true), CaimexModel(id: "no-tools", supportsTools: false)]
        let choices = CaimexModelChoices(models: models, current: "no-tools")
        #expect(choices.ids == ["no-tools", "tools"], "the picker must still show what is selected")
    }

    @Test func untaggedListsHideNothing() {
        let choices = CaimexModelChoices(models: [CaimexModel(id: "a"), CaimexModel(id: "b")], current: "a")
        #expect(choices.ids == ["a", "b"])
        #expect(choices.withoutToolsCount == 0)
    }

    @Test func detailsNameWhatTheGatewaySaid() {
        let locale = Locale(identifier: "en_US")
        let flash = CaimexModel(id: "deepseek-v4-flash", supportsTools: true, contextLength: 1_048_576,
                                inputPricePerMillion: Decimal(string: "0.38"), outputPricePerMillion: Decimal(string: "0.8"),
                                hostingCountry: "ZW", mayTrain: false)
        #expect(flash.details(locale: locale) == [
            "Tool calling", "1M context", "$0.38 in, $0.80 out per 1M tokens", "Hosted in Zimbabwe", "Not used for training",
        ])
        let free = CaimexModel(id: "free", supportsTools: false, inputPricePerMillion: 0, outputPricePerMillion: 0, mayTrain: true)
        #expect(free.details(locale: locale) == ["No tool calling", "Free", "May be used for training"])
        #expect(CaimexModel(id: "bare").details(locale: locale).isEmpty, "nothing is claimed the gateway didn't say")
    }

    @Test func tokenCountsUseShortUnits() {
        let locale = Locale(identifier: "en_US")
        #expect(CaimexModel.tokenCount(1_048_576, locale: locale) == "1M")
        #expect(CaimexModel.tokenCount(1_000_000, locale: locale) == "1M")
        #expect(CaimexModel.tokenCount(131_072, locale: locale) == "128K")
        #expect(CaimexModel.tokenCount(128_000, locale: locale) == "128K")
        #expect(CaimexModel.tokenCount(200_000, locale: locale) == "200K")
        #expect(CaimexModel.tokenCount(1_572_864, locale: locale) == "1.5M")
        #expect(CaimexModel.tokenCount(512, locale: locale) == "512")
    }
}
