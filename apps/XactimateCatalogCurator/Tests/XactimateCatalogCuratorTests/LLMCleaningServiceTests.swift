import Testing
@testable import XactimateCatalogCurator

@Test
func parsesPlainJSONObjectFromLLM() throws {
    let content = """
    {"title":"Ceiling paint after repair","tags":"ceiling,paint","cleaned_description":"Use this when a repaired ceiling area needs paint blending or full repaint.","when_not_to_use":"Do not use when the ceiling is being fully replaced.","room":"Living room","surface":"Ceiling","damage_type":"Paint after patch","keywords":"ceiling repaint,blend paint","synonyms":"paint ceiling,ceiling touch-up","ai_hint":"Match to ceiling paint scope and note whether the repair is localized or full-area."}
    """

    let result = try LLMCleaningService.parseCleanedResult(from: content)
    #expect(result.title == "Ceiling paint after repair")
    #expect(result.tags == "ceiling,paint")
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
