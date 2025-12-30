# PhxPoker

[![Elixir](https://img.shields.io/badge/Elixir-1.16+-4B275F?logo=elixir)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenix-framework)](https://www.phoenixframework.org/)
[![LiveView](https://img.shields.io/badge/LiveView-1.1-32CD32)](https://hexdocs.pm/phoenix_live_view/)

Real-time planning poker built with Phoenix LiveView. No database required.

## Features

- Real-time voting with WebSocket sync
- Multiple card presets (Fibonacci, T-Shirt, Powers of 2, etc.)
- Player and Spectator roles
- Vote statistics (avg, min, max)
- Round history (last 10 rounds)
- Room link sharing with clipboard copy
- Results export as Markdown

## Tech Stack

- **Phoenix 1.8** + **LiveView 1.1** - Real-time UI without JavaScript
- **GenServer** - In-memory room state (no database)
- **PubSub + Presence** - Real-time synchronization
- **Tailwind CSS + daisyUI** - Modern UI components

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Supervision Tree                       │
├─────────────────────────────────────────────────────────────┤
│  Application                                                │
│  ├── PubSub           (message broadcasting)                │
│  ├── Registry         (room process lookup)                 │
│  ├── RoomSupervisor   (DynamicSupervisor)                   │
│  │   └── RoomServer   (1 GenServer per room)                │
│  ├── Presence         (online user tracking)                │
│  └── Endpoint         (HTTP/WebSocket)                      │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Browser ←──WebSocket──→ LiveView ←──PubSub──→ RoomServer (GenServer)
                            ↑                       │
                            └───── broadcast ───────┘
```

1. **LiveView** handles UI events (`phx-click`, `phx-submit`)
2. **RoomServer** manages room state (players, votes, history)
3. **PubSub** broadcasts state changes to all connected clients
4. **Presence** tracks online users per room

### Project Structure

```
lib/
├── planning_poker/
│   ├── application.ex        # Supervision tree
│   └── rooms/
│       ├── room.ex           # Room state struct & logic
│       ├── room_server.ex    # GenServer (1 per room)
│       └── room_supervisor.ex # DynamicSupervisor
└── planning_poker_web/
    ├── live/
    │   ├── lobby_live.ex     # Room creation/joining
    │   └── room_live.ex      # Main game UI
    ├── presence.ex           # Phoenix.Presence
    └── router.ex             # Routes: /, /room/:id
```

## Quick Start

**Prerequisites**: Elixir 1.16+, Erlang/OTP 26+

```bash
# Install dependencies
mix setup

# Start server
mix phx.server
```

Visit [localhost:4000](http://localhost:4000)

## Development

```bash
# Run tests
mix test

# Format code
mix format
```

## License

MIT License - see [LICENSE](LICENSE) file for details.
