import XCTest
@testable import XactimateFieldCapture

final class BackendModelsTests: XCTestCase {
    func testOpenDraftDecodesMessagesAndSections() throws {
        let json = """
        {
          "status": "ok",
          "draft": {
            "job_id": "claim-123",
            "bridge_id": "default",
            "room_order": ["Living room"],
            "messages": [
              {
                "id": "msg-1",
                "role": "user",
                "text": "Living room ceiling needs patch and paint.",
                "created_at": "2026-03-22T12:00:00Z"
              }
            ],
            "items": [
              {
                "id": "item-1",
                "room": "Living room",
                "section": "Ceiling",
                "approved_code": "DRY/PCH",
                "description": "2x2 drywall patch",
                "quantity": "1",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "2x2 patch picture frame",
                "status": "accepted",
                "source": "agent",
                "rationale": "Patch playbook matched the ceiling repair."
              }
            ],
            "updated_at": "2026-03-22T12:05:00Z"
          },
          "grouped_sections": [
            {
              "room": "Living room",
              "section": "Ceiling",
              "note": "Ceiling",
              "items": [
                {
                  "id": "item-1",
                  "room": "Living room",
                  "section": "Ceiling",
                  "approved_code": "DRY/PCH",
                  "description": "2x2 drywall patch",
                  "quantity": "1",
                  "surface": "Ceiling",
                  "damage_type": "Patch",
                  "keywords": "2x2 patch picture frame",
                  "status": "accepted",
                  "source": "agent",
                  "rationale": "Patch playbook matched the ceiling repair."
                }
              ]
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(OpenDraftResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.draft.messages.first?.role, "user")
        XCTAssertEqual(response.groupedSections.first?.items.first?.approvedCode, "DRY/PCH")
    }

    func testDraftPlanResponseDecodesApprovedItem() throws {
        let json = """
        {
          "status": "ok",
          "draft": {
            "job_id": "claim-123",
            "bridge_id": "default",
            "room_order": ["Living room"],
            "messages": [],
            "items": [],
            "updated_at": "2026-03-22T12:05:00Z"
          },
          "grouped_sections": [],
          "plan": {
            "approved_count": 1,
            "needs_review_count": 0,
            "unresolved_count": 0,
            "items": [
              {
                "source": {
                  "item_id": "item-1",
                  "description": "2x2 ceiling patch",
                  "item_type": "line_item",
                  "room": "Living room",
                  "section": "Ceiling",
                  "surface": "Ceiling",
                  "damage_type": "Patch",
                  "keywords": "picture frame",
                  "quantity": "1",
                  "note": "",
                  "approved_code": "DRY/PCH"
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
        }
        """

        let response = try JSONDecoder().decode(DraftPlanResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.plan.approvedCount, 1)
        XCTAssertEqual(response.plan.items.first?.approvedCandidate?.item.code, "DRY/PCH")
    }
}
