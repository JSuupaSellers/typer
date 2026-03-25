import Testing
@testable import XactimateCatalogCurator

@Test
func parsesPlainJSONObjectFromLLM() throws {
    let content = """
    {"title":"Ceiling paint after repair","tags":"ceiling,paint","cleaned_description":"Use this when a repaired ceiling area needs paint blending or full repaint.","when_not_to_use":"Do not use when the ceiling is being fully replaced.","room":"Living room","surface":"Ceiling","damage_type":"Paint after patch","keywords":"ceiling repaint,blend paint","synonyms":"paint ceiling,ceiling touch-up","ai_hint":"Match to ceiling paint scope and note whether the repair is localized or full-area."}
    """

    let result = try LLMCleaningService.parseCleanedResult(from: content)
    #expect(result.title == "Ceiling paint after repair")
    #expect(result.tags == "ceiling, paint")
    #expect(result.cleanedDescription.contains("repaired ceiling"))
    #expect(result.surface == "Ceiling")
}

@Test
func parsesFencedJSONObjectFromLLM() throws {
    let content = """
    ```json
    {"title":"Drywall patch","tags":"drywall,patch","cleaned_description":"Use for a small drywall opening that needs patch and finish.","when_not_to_use":"Avoid when the entire panel is being replaced.","room":"Bedroom","surface":"Wall","damage_type":"Patch","keywords":"drywall patch,small opening","synonyms":"patch wall,repair opening","ai_hint":"Mention patch dimensions and whether texture or paint follows."}
    ```
    """

    let result = try LLMCleaningService.parseCleanedResult(from: content)
    #expect(result.title == "Drywall patch")
    #expect(result.aiHint.contains("patch dimensions"))
    #expect(result.whenNotToUse.contains("entire panel"))
}

@Test
func parsesStructuredRecommendationQueryFromLLM() throws {
    let content = """
    ```json
    {"narrative":"Bedroom ceiling has a 2x2 patch, picture frame texture, and repaint.","room":"Bedroom","surface":"Ceiling","damage_type":"Patch and repaint","keywords":"2x2 patch,picture frame,ceiling paint"}
    ```
    """

    let result = try LLMCleaningService.parseStructuredRecommendationQuery(from: content)
    #expect(result.room == "Bedroom")
    #expect(result.surface == "Ceiling")
    #expect(result.damageType == "Patch and repaint")
}

@Test
func compactsVerboseJSONObjectFromLLM() throws {
    let content = """
    {"title":"Ceiling repair repaint after localized drywall opening and picture frame texture blending","tags":"ceiling, paint, drywall, repair, extra tag","cleaned_description":"Use this when a localized ceiling opening has been patched, textured, and now needs concise repaint guidance for the estimator to carry forward without extra narrative.","when_not_to_use":"Do not use this when the whole ceiling is being torn out and replaced or when the scope is really wall-only paint work.","room":"Large upstairs living room area","surface":"Textured painted ceiling surface","damage_type":"Localized drywall patch with repaint and texture blend","keywords":"2x2 patch,picture frame,ceiling paint,localized opening,texture blend,repair,extra","synonyms":"paint ceiling after patch,ceiling blend,localized ceiling repair repaint,another synonym,extra synonym","ai_hint":"Choose this when the scope is a small repaired ceiling area that still needs texture and paint, but avoid long explanations."}
    """

    let result = try LLMCleaningService.parseCleanedResult(from: content)
    #expect(result.title == "Ceiling repair repaint after localized drywall")
    #expect(result.tags == "ceiling, paint, drywall, repair")
    #expect(result.keywords == "2x2 patch, picture frame, ceiling paint, localized opening, texture blend, repair")
    #expect(result.synonyms == "paint ceiling after patch, ceiling blend, localized ceiling repair repaint, another synonym")
    #expect(result.aiHint.count <= 120)
}
