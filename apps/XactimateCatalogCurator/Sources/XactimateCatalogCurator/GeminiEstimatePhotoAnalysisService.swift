import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum EstimatePhotoAnalysisError: LocalizedError {
    case invalidEndpoint
    case couldNotPrepareImage
    case missingOutput
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Gemini endpoint URL is invalid."
        case .couldNotPrepareImage:
            return "The image could not be prepared for analysis."
        case .missingOutput:
            return "The photo analysis response did not contain usable output."
        case .invalidResponse:
            return "The photo analysis response could not be parsed."
        }
    }
}

struct GeminiEstimatePhotoAnalysisService {
    func analyzePhoto(
        fileURL: URL,
        settings: LLMSettings
    ) async throws -> EstimatePhotoExtraction {
        let model = settings.estimatePhotoModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw EstimatePhotoAnalysisError.invalidEndpoint
        }

        let preparedImage = try PreparedVisionImage.make(from: fileURL)
        let payload = GeminiGenerateContentRequest(
            contents: [
                .init(parts: [
                    .text(userPrompt(for: fileURL, settings: settings)),
                    .inlineData(mimeType: preparedImage.mimeType, data: preparedImage.base64Data),
                ])
            ],
            generationConfig: .catalogCodeExtraction
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "GeminiEstimatePhotoAnalysisService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body.isEmpty ? "The Gemini API returned status \(http.statusCode)." : body
            ])
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard
            let outputText = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            !outputText.isEmpty
        else {
            throw EstimatePhotoAnalysisError.missingOutput
        }

        return try Self.parseExtraction(from: outputText)
    }

    static func parseExtraction(from outputText: String) throws -> EstimatePhotoExtraction {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw EstimatePhotoAnalysisError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(EstimatePhotoExtraction.self, from: data)

        let dedupedCodes = Array(
            Set(
                decoded.detectedCodes.compactMap { code -> CatalogCode? in
                    let normalized = CatalogCode(category: code.category, selector: code.selector)
                    return normalized.category.isEmpty || normalized.selector.isEmpty ? nil : normalized
                }
            )
        ).sorted()

        return EstimatePhotoExtraction(
            detectedCodes: dedupedCodes,
            note: decoded.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func userPrompt(for fileURL: URL, settings: LLMSettings) -> String {
        """
        \(settings.estimatePhotoPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

        Photo filename: \(fileURL.lastPathComponent)
        """
    }
}

private struct PreparedVisionImage {
    let mimeType: String
    let base64Data: String

    static func make(from fileURL: URL) throws -> PreparedVisionImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        let maxDimension: CGFloat = 2200
        let targetSize = scaledSize(
            for: CGSize(width: image.width, height: image.height),
            maxDimension: maxDimension
        )
        let width = max(Int(targetSize.width.rounded(.up)), 1)
        let height = max(Int(targetSize.height.rounded(.up)), 1)

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaledImage = context.makeImage() else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        let jpegData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        CGImageDestinationAddImage(destination, scaledImage, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw EstimatePhotoAnalysisError.couldNotPrepareImage
        }

        return PreparedVisionImage(mimeType: "image/jpeg", base64Data: jpegData.base64EncodedString())
    }

    private static func scaledSize(for original: CGSize, maxDimension: CGFloat) -> CGSize {
        guard original.width > 0, original.height > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }

        let largestSide = max(original.width, original.height)
        guard largestSide > maxDimension else { return original }
        let scale = maxDimension / largestSide
        return CGSize(width: original.width * scale, height: original.height * scale)
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        static func text(_ text: String) -> Part {
            Part(text: text, inlineData: nil)
        }

        static func inlineData(mimeType: String, data: String) -> Part {
            Part(text: nil, inlineData: InlineData(mimeType: mimeType, data: data))
        }
    }

    struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    struct GenerationConfig: Encodable {
        let responseMimeType: String
        let responseJsonSchema: JSONSchema

        static var catalogCodeExtraction: GenerationConfig {
            GenerationConfig(
                responseMimeType: "application/json",
                responseJsonSchema: .catalogCodeExtraction
            )
        }
    }

    struct JSONSchema: Encodable {
        let type: String
        let properties: [String: JSONSchemaProperty]
        let required: [String]
        let additionalProperties: Bool

        static var catalogCodeExtraction: JSONSchema {
            JSONSchema(
                type: "object",
                properties: [
                    "detected_codes": .array(
                        items: .object(
                            properties: [
                                "category": .string(description: "Exact CAT code visible in the image."),
                                "selector": .string(description: "Exact SEL code visible in the image."),
                            ],
                            required: ["category", "selector"]
                        )
                    ),
                    "note": .string(description: "Brief summary of what was readable in the image."),
                ],
                required: ["detected_codes", "note"],
                additionalProperties: false
            )
        }
    }

    final class JSONSchemaProperty: Encodable {
        let type: String
        let description: String?
        let properties: [String: JSONSchemaProperty]?
        let required: [String]?
        let additionalProperties: Bool?
        let items: JSONSchemaProperty?

        init(
            type: String,
            description: String?,
            properties: [String: JSONSchemaProperty]?,
            required: [String]?,
            additionalProperties: Bool?,
            items: JSONSchemaProperty?
        ) {
            self.type = type
            self.description = description
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
            self.items = items
        }

        static func string(description: String) -> JSONSchemaProperty {
            JSONSchemaProperty(type: "string", description: description, properties: nil, required: nil, additionalProperties: nil, items: nil)
        }

        static func array(items: JSONSchemaProperty) -> JSONSchemaProperty {
            JSONSchemaProperty(type: "array", description: nil, properties: nil, required: nil, additionalProperties: nil, items: items)
        }

        static func object(properties: [String: JSONSchemaProperty], required: [String]) -> JSONSchemaProperty {
            JSONSchemaProperty(type: "object", description: nil, properties: properties, required: required, additionalProperties: false, items: nil)
        }
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}
