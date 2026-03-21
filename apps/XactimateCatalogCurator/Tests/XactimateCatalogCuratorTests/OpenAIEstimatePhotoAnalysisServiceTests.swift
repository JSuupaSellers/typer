import Testing
@testable import XactimateCatalogCurator

@Test
func parsesEstimatePhotoExtractionAndDeduplicatesCodes() throws {
    let output = """
    {"detected_codes":[{"category":"pnt","selector":"sp"},{"category":"PNT","selector":"SP"},{"category":"dry","selector":"pch"}],"note":"Visible line items on estimate page."}
    """

    let result = try OpenAIEstimatePhotoAnalysisService.parseExtraction(from: output)

    #expect(result.detectedCodes == [
        CatalogCode(category: "DRY", selector: "PCH"),
        CatalogCode(category: "PNT", selector: "SP"),
    ])
    #expect(result.note == "Visible line items on estimate page.")
}
