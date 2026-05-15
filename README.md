# HouseCall

AI-powered primary care platform with 24/7 patient monitoring and physician
supervision — a full care loop from evaluation to prescription.

## Repository layout

| Path | Contents |
|---|---|
| `docs/` | Product and architecture planning — `PROJECT.md`, `ARCHITECTURE.md`, `USER_GUIDE.md` |
| `HouseCall/` | Patient iOS app (SwiftUI, encrypted Core Data) |
| `HouseCallTests/`, `HouseCallUITests/` | iOS test targets |
| `backend/` | Cloud backend services (Go) — see `backend/README.md` |
| `openspec/` | Spec-driven change proposals and capability specs |
| `CLAUDE.md`, `AGENTS.md` | Instructions for AI assistants working in this repo |

## Planning

- Platform vision and roadmap: [`docs/PROJECT.md`](docs/PROJECT.md)
- System architecture and decision log: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
