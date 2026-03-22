import XCTest
@testable import XactimateFieldCapture

final class BackendModelsTests: XCTestCase {
    func testCaptureDraftDecodesJobPayload() throws {
        let json = """
        {
          "status": "ok",
          "message": "Capture draft prepared.",
          "transcript": "Paint the ceiling after a 2x2 patch.",
          "audio_filename": "note.m4a",
          "photo_count": 2,
          "photo_filenames": ["photo-1.jpg", "photo-2.jpg"],
          "job": {
            "job_id": "claim-123",
            "bridge_id": "default",
            "items": [
              {
                "item_id": "scope-1",
                "description": "Paint the ceiling after a 2x2 patch.",
                "room": "Living room",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "picture frame",
                "quantity": "1"
              }
            ]
          }
        }
        """

        let response = try JSONDecoder().decode(CaptureDraftResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.photoCount, 2)
        XCTAssertEqual(response.job.items.first?.description, "Paint the ceiling after a 2x2 patch.")
    }

    func testPlanResponseDecodesApprovedItem() throws {
        let json = """
        {
          "approved_count": 1,
          "needs_review_count": 0,
          "unresolved_count": 0,
          "items": [
            {
              "source": {
                "item_id": "scope-1",
                "description": "2x2 ceiling patch",
                "room": "Living room",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "picture frame",
                "quantity": "1"
              },
              "candidates": [],
              "approved_candidate": {
                "item": {
                  "code": "DRY/PCH",
                  "category": "DRY",
                  "selector": "PCH",
                  "description": "Drywall patch 2x2",
                  "unit": "EA",
                  "details": "Patch a small ceiling opening."
                },
                "score": 52.0,
                "confidence": "high",
                "reasons": ["Patch playbook matched the repair scope."]
              },
              "status": "approved",
              "review_reason": ""
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(PlanResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.approvedCount, 1)
        XCTAssertEqual(response.items.first?.approvedCandidate?.item.code, "DRY/PCH")
    }
}
