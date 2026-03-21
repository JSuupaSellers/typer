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
            return "The OpenAI base URL is invalid."
        case .couldNotPrepareImage:
            return "The image could not be prepared for analysis."
        case .missingOutput:
            return "The photo analysis response did not contain usable output."
        case .invalidResponse:
            return "The photo analysis response could not be parsed."
        }
    }
}

struct OpenAIEstimatePhotoAnalysisService {
    func analyzePhoto(
        fileURL: URL,
        settings: LLMSettings
    ) async throws -> EstimatePhotoExtraction {
        guard let endpoint = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appending(path: "responses")
        else {
            throw EstimatePhotoAnalysisError.invalidEndpoint
        }

        let preparedImage = try PreparedVisionImage.make(from: fileURL)
        let payload = ResponsesRequest(
            model: settings.visionModel.trimmingCharacters(in: .whitespacesAndNewlines),
            input: [
                .init(
                    role: "user",
                    content: [
                        .text(text: userPrompt(for: fileURL, settings: settings)),
                        .image(imageURL: preparedImage.dataURL, detail: "high"),
                    ]
                )
            ],
            text: .init(format: .catalogCodeSchema),
            maxOutputTokens: 700
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "OpenAIEstimatePhotoAnalysisService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body.isEmpty ? "The OpenAI vision API returned status \(http.statusCode)." : body
            ])
        }

        let decoded = try JSONDecoder().decode(ResponsesCreateResponse.self, from: data)
        guard let outputText = decoded.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty else {
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
    let dataURL: String

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

        let base64 = jpegData.base64EncodedString()
        return PreparedVisionImage(dataURL: "data:image/jpeg;base64,\(base64)")
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

private struct ResponsesRequest: Encodable {
    struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable {
        let type: String
        let text: String?
        let imageURL: String?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
            case detail
        }

        static func text(text: String) -> InputContent {
            InputContent(type: "input_text", text: text, imageURL: nil, detail: nil)
        }

        static func image(imageURL: String, detail: String) -> InputContent {
            InputContent(type: "input_image", text: nil, imageURL: imageURL, detail: detail)
        }
    }

    struct TextConfiguration: Encodable {
        let format: TextFormat
    }

    struct TextFormat: Encodable {
        let type: String
        let name: String
        let strict: Bool
        let schema: JSONSchema

        static var catalogCodeSchema: TextFormat {
            TextFormat(
                type: "json_schema",
                name: "estimate_photo_codes",
                strict: true,
                schema: .catalogCodeExtraction
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
                                "category": .string,
                                "selector": .string,
                            ],
                            required: ["category", "selector"]
                        )
                    ),
                    "note": .string,
                ],
                required: ["detected_codes", "note"],
                additionalProperties: false
            )
        }
    }

    final class JSONSchemaProperty: Encodable {
        let type: String
        let properties: [String: JSONSchemaProperty]?
        let required: [String]?
        let additionalProperties: Bool?
        let items: JSONSchemaProperty?

        init(
            type: String,
            properties: [String: JSONSchemaProperty]?,
            required: [String]?,
            additionalProperties: Bool?,
            items: JSONSchemaProperty?
        ) {
            self.type = type
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
            self.items = items
        }

        static var string: JSONSchemaProperty {
            JSONSchemaProperty(type: "string", properties: nil, required: nil, additionalProperties: nil, items: nil)
        }

        static func array(items: JSONSchemaProperty) -> JSONSchemaProperty {
            JSONSchemaProperty(type: "array", properties: nil, required: nil, additionalProperties: nil, items: items)
        }

        static func object(properties: [String: JSONSchemaProperty], required: [String]) -> JSONSchemaProperty {
            JSONSchemaProperty(type: "object", properties: properties, required: required, additionalProperties: false, items: nil)
        }
    }

    let model: String
    let input: [InputMessage]
    let text: TextConfiguration
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case text
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct ResponsesCreateResponse: Decodable {
    let outputText: String?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
    }
}
