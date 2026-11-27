# physician-web-app (delta)

## ADDED Requirements

### Requirement: Draft Provenance Display

The physician web app SHALL show, for each recommendation in the review queue
and on its detail view, the model name and prompt version that drafted it.
Recommendations created before provenance was recorded SHALL show that the
provenance is unknown.

#### Scenario: Provenance is shown during review

**Given** a pending recommendation drafted with a recorded model and prompt version
**When** the physician opens the review queue
**Then** the recommendation shows the model name and prompt version

#### Scenario: Older recommendations degrade safely

**Given** a recommendation created before provenance was recorded
**When** the physician views it
**Then** it shows "provenance unknown" instead of failing to render
