# How to Release a New Game – RGS Architecture Guide

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture Overview](#2-architecture-overview)
   - 2.1 Projects Involved
   - 2.2 Migration Packages
   - 2.3 Data Flow
3. [Gaming Service Implementation](#3-gaming-service-implementation)
   - 3.1 Game Engine Structure
   - 3.2 Engine Class Implementation
   - 3.3 Game Configuration
   - 3.4 Database Migrations
   - 3.5 RNG Implementation (Provably Fair)
   - 3.6 Game Runner Worker
4. [Server Implementation](#4-server-implementation)
   - 4.1 Feature Status System
   - 4.2 Feature Status Migration
5. [Client Implementation](#5-client-implementation)
   - 5.1 Component Structure
   - 5.2 Route Registration
   - 5.3 Socket Handlers
   - 5.4 Navigation Integration
6. [Admin Panel Implementation](#6-admin-panel-implementation)
7. [Release Process](#7-release-process)
   - 7.1 Phase 1: Development (Staging)
   - 7.2 Phase 2: QA Verification
   - 7.3 Phase 3: Production Preparation
   - 7.4 Phase 4: Deploy to Production
   - 7.5 Phase 5: Slow Release
8. [Release Checklist](#8-release-checklist)
9. [Troubleshooting](#9-troubleshooting)
10. [Reference: Lotto Beast Implementation](#10-reference-lotto-beast-implementation)
11. [Executive Summary (Non-Technical)](#11-executive-summary-non-technical)

---

## 1. Introduction

This document describes the complete process for adding and releasing a new game in Blaze's RGS (Remote Gaming Service) architecture. It covers all components from initial development through production deployment with controlled slow release.

**Reference Implementation**: This tutorial uses the **Lotto Beast** game as a case study, documenting the patterns and configurations used in its successful release.

**Target Audience**: Backend engineers, frontend engineers, and release managers involved in game development and deployment.

**Scope**: This guide covers multiplayer games in the RGS architecture. Single-player games and third-party provider integrations follow different patterns.

---

## 2. Architecture Overview

### 2.1 Projects Involved

The game release process touches four main projects, each with specific responsibilities:

| Project | Role | Responsibilities |
|---------|------|------------------|
| **gaming-service-betbr** | RGS Backend | Game logic, tick system, bet processing, RNG, settlement |
| **server-betbr** | OLTP Backend | Feature flags, waitlist management, user settings |
| **client-betbr** | Frontend | Game UI, animations, socket connections, Redux state |
| **admin-betbr** | Admin Panel | Game status monitoring, release controls, bet lookup |

### 2.2 Migration Packages

Database changes are managed through dedicated packages. Each package must be versioned and published before deployment.

| Package | Database | Purpose |
|---------|----------|---------|
| `@blazecode/gaming-service-pg-controller` | Gaming DB | Game tables, bet tables, partitions, enums |
| `@blazecode/oltp-pg-controller` | OLTP DB | General settings (legacy) |
| `@blazecode/subwriter-pg-controller` | Subwriter DB | Feature status, waitlist, feature access |

**Important**: Migrations run automatically during deployment. Always test in staging before production.

### 2.3 Data Flow

The system uses a distributed architecture with real-time communication:

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│     Client      │────▶│      Server      │────▶│  Gaming Service │
│    (React)      │◀────│    (Express)     │◀────│     (RGS)       │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                       │                        │
        ▼                       ▼                        ▼
   Socket.IO              Feature Flags            Game Ticks
   Real-time              Waitlist                 Bet Processing
   Updates                Access Control           Settlements
```

**Key flows**:
- **Game ticks**: Gaming Service → Socket.IO → Client (every `tickMs`)
- **Bet placement**: Client → Server → Gaming Service → Database
- **Access control**: Client → Server (feature status check) → Allow/Deny

---

## 3. Gaming Service Implementation

### 3.1 Game Engine Structure

Each game is implemented as an "engine" following a standardized structure.

**Location**: `/packages/games/engines/{game-name}-engine/`

| File/Directory | Purpose |
|----------------|---------|
| `index.js` | Main engine class extending `MultiplayerEngine` |
| `config.js` | Game configuration (timing, limits, multipliers) |
| `workers/game-runner.js` | Background process that runs game ticks |
| `workers/settlement-worker.js` | Background process for bet settlement |
| `repos/{game}-games-repo.js` | Database queries for game records |
| `repos/{game}-bets-repo.js` | Database queries for bet records |
| `services/{game}-outcomes-service.js` | Win/loss determination logic |
| `services/{game}-marshalling-service.js` | Response formatting |
| `services/{game}-validator-service.js` | Bet validation rules |
| `utils/calculations.js` | Multiplier and payout calculations |
| `utils/tick-game-specific.js` | Custom fields added to each tick |
| `tests/` | Unit and integration tests |

### 3.2 Engine Class Implementation

The engine class extends `MultiplayerEngine` and implements game-specific methods.

**File**: `/packages/games/engines/{game}-engine/index.js`

```javascript
const MultiplayerEngine = require('../multiplayer-engine');
const gamesRepo = require('./repos/{game}-games-repo');
const betsRepo = require('./repos/{game}-bets-repo');
const { marshal } = require('./services/{game}-marshalling-service');
const config = require('./config');

class NewGameEngine extends MultiplayerEngine {
  static GAME_ID = 'new-game';

  constructor(options) {
    super({
      ...options,
      gamesRepo,
      betsRepo,
      marshal,
    });
  }

  buildConfig() {
    return config;
  }

  getRng() {
    return require('../../math/new-game/new-game-rng');
  }

  getAddGameSpecificFields() {
    return require('./utils/tick-game-specific').addGameSpecificFields;
  }

  getSettlementFn() {
    return require('./services/{game}-outcomes-service').settlementFunction;
  }

  getValidatorService() {
    return require('./services/{game}-validator-service');
  }
}

module.exports = NewGameEngine;
```

**Required methods**:
- `buildConfig()`: Returns game configuration object
- `getRng()`: Returns the RNG function for Provably Fair
- `getAddGameSpecificFields()`: Returns function that adds custom tick fields
- `getSettlementFn()`: Returns function that determines bet outcomes
- `getValidatorService()`: Returns validation service for bet rules

### 3.3 Game Configuration

The configuration file defines all game parameters.

**File**: `/packages/games/engines/{game}-engine/config.js`

```javascript
module.exports = {
  gameType: 'new_game',
  gameName: 'NewGame',
  rooms: [1],

  betParams: ['target', 'bet_type'],

  limits: {
    minBet: 0.1,
    maxBet: 100000,
    maxProfit: 5000000,
  },

  rules: {
    maxBetsPerRound: 50,
  },

  multipliers: {
    // Game-specific multiplier definitions
  },

  timing: {
    preRoundMs: 15000,
    postRoundMs: 5000,
    rollingMs: 10000,
    tickMs: 1000,
  },

  database: {
    games: 'new_game_games',
    bets: 'new_game_bets',
    gameIdColumn: 'new_game_game_id',
    betSequence: 'new_game_bets_id_seq',
  },

  events: {
    MultiplayerGameEnded: 'NewGameGameEnded',
    MultiBetResulted: 'MultiNewGameBetResulted',
  },
};
```

**Configuration parameters explained**:

| Parameter | Description | Example (Lotto Beast) |
|-----------|-------------|----------------------|
| `timing.preRoundMs` | Betting window before rolling starts | 15500ms |
| `timing.rollingMs` | Animation/reveal duration | 12000ms |
| `timing.postRoundMs` | Results display before next round | 5000ms |
| `timing.tickMs` | Broadcast frequency to clients | 1000ms |
| `limits.minBet` | Minimum allowed bet | 0.1 |
| `limits.maxBet` | Maximum allowed bet | 100000 |
| `limits.maxProfit` | Maximum payout per round (risk control) | 5000000 |
| `rules.maxBetsPerRound` | Bets per user per round | 50 |

### 3.4 Database Migrations

#### 3.4.1 Games and Bets Tables

**File**: `@blazecode/gaming-service-pg-controller/src/migrations/YYYYMMDDHHMMSS-new-game.js`

The migration must create:

1. **Status enum**: Game state machine values
2. **Games table**: One record per game round
3. **Bets table**: Partitioned by month for performance
4. **Enum updates**: Add game to existing bet/transaction enums

```javascript
'use strict';

module.exports = {
  async up(queryInterface, Sequelize) {
    // 1. Create status enum
    await queryInterface.sequelize.query(`
      CREATE TYPE enum_new_game_games_status AS ENUM ('waiting', 'rolling', 'complete');
    `);

    // 2. Create games table
    await queryInterface.createTable('new_game_games', {
      id: { type: Sequelize.BIGINT, primaryKey: true },
      status: { type: 'enum_new_game_games_status', allowNull: false, defaultValue: 'waiting' },
      // Game-specific result fields
      result_field_1: Sequelize.INTEGER,
      result_field_2: Sequelize.INTEGER,
      multiplayer_game_id: { type: Sequelize.INTEGER, references: { model: 'multiplayer_games', key: 'id' } },
      server_roll_id: { type: Sequelize.UUID, references: { model: 'server_rolls', key: 'id' } },
      created_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
      updated_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
    });

    // 3. Create indexes
    await queryInterface.addIndex('new_game_games', ['status']);
    await queryInterface.addIndex('new_game_games', ['multiplayer_game_id']);

    // 4. Create partitioned bets table
    await queryInterface.sequelize.query(`
      CREATE TABLE new_game_bets (
        id BIGINT NOT NULL,
        new_game_game_id BIGINT NOT NULL,
        user_id UUID NOT NULL,
        target VARCHAR(100),
        bet_type VARCHAR(50),
        amount DECIMAL(20, 8) NOT NULL,
        currency VARCHAR(10) NOT NULL,
        multiplier DECIMAL(20, 8),
        status VARCHAR(20) NOT NULL DEFAULT 'pending',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id, created_at)
      ) PARTITION BY RANGE (created_at);
    `);

    // 5. Create 24 monthly partitions
    const months = generateMonthlyPartitions(2025, 2027);
    for (const [name, start, end] of months) {
      await queryInterface.sequelize.query(`
        CREATE TABLE new_game_bets_${name} PARTITION OF new_game_bets
        FOR VALUES FROM ('${start}') TO ('${end}');
      `);
    }

    // 6. Add to enums
    await queryInterface.sequelize.query(`ALTER TYPE enum_bets_type ADD VALUE IF NOT EXISTS 'new_game';`);
    await queryInterface.sequelize.query(`ALTER TYPE enum_transactions_type ADD VALUE IF NOT EXISTS 'new_game';`);
  },

  async down(queryInterface) {
    await queryInterface.dropTable('new_game_bets');
    await queryInterface.dropTable('new_game_games');
    await queryInterface.sequelize.query('DROP TYPE IF EXISTS enum_new_game_games_status;');
  },
};
```

**Important**: Bet tables use monthly partitioning for performance. Create partitions for at least 2 years ahead.

#### 3.4.2 Multiplayer Games Seed

**File**: `@blazecode/gaming-service-pg-controller/src/seeds/YYYYMMDDHHMMSS-new-game.js`

```javascript
'use strict';

module.exports = {
  async up(queryInterface) {
    // Register game in multiplayer_games
    await queryInterface.sequelize.query(`
      INSERT INTO multiplayer_games (id, game, description, active, slug, bonus_round_available, created_at, updated_at)
      VALUES (
        (SELECT COALESCE(MAX(id), 0) + 1 FROM multiplayer_games),
        'new_game_room_1',
        'New Game Room 1',
        true,
        'new-game',
        false,
        NOW(),
        NOW()
      )
      ON CONFLICT (game) DO NOTHING;
    `);

    // Create setting (disabled by default)
    await queryInterface.sequelize.query(`
      INSERT INTO settings (key, value, created_at, updated_at)
      VALUES ('new_game_enabled', '0', NOW(), NOW())
      ON CONFLICT (key) DO NOTHING;
    `);
  },

  async down(queryInterface) {
    await queryInterface.sequelize.query(`DELETE FROM multiplayer_games WHERE game = 'new_game_room_1';`);
    await queryInterface.sequelize.query(`DELETE FROM settings WHERE key = 'new_game_enabled';`);
  },
};
```

### 3.5 RNG Implementation (Provably Fair)

The RNG function converts a SHA-256 hash into deterministic game results.

**File**: `/packages/math/new-game/new-game-rng.js`

```javascript
const { generateCoreRngValues } = require('../core-rng');

/**
 * Converts SHA-256 hash to game results
 * @param {string} hash - 64 hex characters from server roll
 * @returns {Object} Game-specific result values
 */
const getNewGameRng = (hash) => {
  const rngValues = generateCoreRngValues(hash);

  // Map to game-specific results
  const results = rngValues.map((value) => value % 10000);

  return {
    result_1: results[0],
    result_2: results[1],
    // ... additional result fields
  };
};

module.exports = getNewGameRng;
```

**Provably Fair requirements**:
- RNG must be deterministic (same hash → same result)
- Hash comes from `server_rolls` table
- Results can be verified by players

### 3.6 Game Runner Worker

The game runner executes ticks at regular intervals.

**File**: `/packages/games/engines/new-game-engine/workers/game-runner.js`

```javascript
const NewGameEngine = require('../index');
const { dbPool } = require('../../../shared/postgres');

const engine = new NewGameEngine({ db: dbPool });

const runGameLoop = async () => {
  const config = engine.buildConfig();

  setInterval(async () => {
    try {
      for (const roomId of config.rooms) {
        await engine.executeTick({ db: dbPool, roomId });
      }
    } catch (error) {
      console.error('Game tick error:', error);
    }
  }, config.timing.tickMs);
};

runGameLoop();
```

**Add to package.json**:
```json
{
  "scripts": {
    "prod:new-game-game-server": "node packages/games/engines/new-game-engine/workers/game-runner.js"
  }
}
```

### 3.7 Register Engine

**File**: `/packages/rgs-core/engine-factory.js`

```javascript
const NewGameEngine = require('../games/engines/new-game-engine/index.js');

const engines = {
  'new-game': new NewGameEngine({ db: dbPool }),
  // ... other engines
};
```

---

## 4. Server Implementation

### 4.1 Feature Status System

The feature status system controls game access with five states:

| Status | Game Access | Waitlist | Use Case |
|--------|-------------|----------|----------|
| `globally_available` | Everyone | N/A | Public release |
| `restricted_access` | Whitelist only | Closed | Beta testing |
| `waitlist_maintenance` | Everyone | Closed | Normal operation, waitlist off |
| `game_maintenance` | Nobody | Open | Pre-release hype |
| `global_maintenance` | Nobody | Closed | Emergency shutdown |

**State progression for release**:
```
game_maintenance → restricted_access → globally_available
     (Dev)            (Beta)              (Public)
```

### 4.2 Feature Status Migration

**File**: `@blazecode/subwriter-pg-controller/src/seeds/YYYYMMDDHHMMSS-add-new-game-feature-status.js`

```javascript
'use strict';

module.exports = {
  async up(queryInterface) {
    await queryInterface.sequelize.query(`
      INSERT INTO feature_status (id, feature_name, status, created_at, updated_at)
      VALUES (DEFAULT, 'new_game_room_1', 'game_maintenance', NOW(), NOW())
      ON CONFLICT (feature_name) DO NOTHING;
    `);
  },

  async down(queryInterface) {
    await queryInterface.sequelize.query(`DELETE FROM feature_status WHERE feature_name = 'new_game_room_1';`);
  },
};
```

### 4.3 Update Constants

**File**: `/packages/waitlist-feature/src/constants.js`

```javascript
const FEATURES = [
  // ... existing games
  'new_game_room_1',
];
```

---

## 5. Client Implementation

### 5.1 Component Structure

**Location**: `/src/casino/originals/new-game/`

| Path | Purpose |
|------|---------|
| `NewGame.js` | Main component (entry point) |
| `constants.js` | Game-specific constants |
| `logic/index.js` | Redux reducer and actions |
| `hooks/useGameHooks.js` | Asset loading, initialization |
| `hooks/use-animation.js` | Animation controllers |
| `controller/` | Betting UI components |
| `canvas/` | Pixi.js rendering |
| `LiveBetTable/` | Real-time bet display |
| `assets/` | Images, Spine animations |

### 5.2 Route Registration

**File**: `/src/casino/CasinoPage.js`

```javascript
import Loadable from 'react-loadable';

const NewGame = Loadable({
  loader: () => import('./originals/new-game/NewGame'),
  loading: PageLoadable,
  delay: 1000,
});

// During development (admin-only):
{isAdmin && <Route path={`${base}/new-game`} component={NewGame} />}

// After release (public):
<Route path={`${base}/new-game`} component={NewGame} />
```

### 5.3 Socket Handlers

**File**: `/src/app/networking/socketio-blaze-originals.js`

```javascript
this.handlers = {
  'new_game.tick': new SocketUpdate(store),
  'new_game.user-bets-result': new SocketUpdateBetsResult(store),
};
```

### 5.4 Navigation Integration

**File**: `/src/app/left-bar/constants.js`

```javascript
{
  testId: 'left-bar-new-game',
  label: 'new_game',
  game: ORIGINAL_GAMES.new_game,
  to: '/games/new-game',
  iconSrc: theme.leftBar[ORIGINAL_GAMES.new_game],
  soon: false,
  onlyLogged: true,
  isAdmin: true,  // Remove after global release
  order: 10,
},
```

### 5.5 Game Configuration

**File**: `/src/casino/originals/core/config/games-config.js`

```javascript
export const GAME_CONFIGS = {
  'new-game': {
    displayName: 'New Game',
    cacheTime: { history: 60000, limits: 300000, lastGame: 30000 },
    roomId: 'new_game_room_1',
  },
};
```

### 5.6 Game Constants

**File**: `/src/app/constants/original-games.js`

```javascript
const ORIGINAL_GAMES = {
  // ... existing games
  new_game: 'new-game',
};
```

---

## 6. Admin Panel Implementation

### 6.1 Game Status Configuration

**File**: `/src/casino/game-status/tab-games-status/const.js`

```javascript
export const GAMES_MAP = [
  {
    name: 'New Game',
    slug: 'new-game',
    featureKey: 'new-game',
    serverKey: 'new_game_enabled',
    gamingKey: 'new_game_enabled',
    autobetType: 'single',
    freeBonusKey: null,
    healthKey: 'BetSlip-new-game',
  },
];
```

### 6.2 Bet Search

**File**: `/src/originals/search-new-game-bet.js`

```javascript
import React from 'react';
import SearchBetForm from './components/SearchBetForm';

const SearchNewGameBet = () => (
  <SearchBetForm
    gameType="new_game"
    endpoint="/admin/originals/new-game/bets"
    fields={['id', 'user_id', 'amount', 'target', 'multiplier', 'status']}
  />
);

export default SearchNewGameBet;
```

---

## 7. Release Process

### 7.1 Phase 1: Development (Staging)

**Duration**: 2-4 weeks

| Task | Owner | Description |
|------|-------|-------------|
| 1.1 | Backend | Create game engine (index.js, config.js) |
| 1.2 | Backend | Implement RNG function |
| 1.3 | Backend | Create database migrations |
| 1.4 | Backend | Create database seeds |
| 1.5 | Backend | Implement game runner worker |
| 1.6 | Backend | Write unit and integration tests |
| 1.7 | Backend | Create feature status migration |
| 1.8 | Frontend | Create game component |
| 1.9 | Frontend | Implement UI and animations |
| 1.10 | Frontend | Add socket handlers |
| 1.11 | Frontend | Configure Redux store |
| 1.12 | Frontend | Add route (admin-only) |
| 1.13 | Admin | Add to game status dashboard |
| 1.14 | Admin | Create bet search interface |

### 7.2 Phase 2: QA Verification

**Duration**: 1-2 weeks

**Run migrations**:
```bash
# Gaming Service
npm run db:migrate

# Server
npm run db:migrate
```

**Verification checklist**:

| Item | Expected Value | Verified |
|------|----------------|----------|
| Games table created | `new_game_games` exists | ☐ |
| Bets table created | `new_game_bets` with partitions | ☐ |
| Partitions created | 24 monthly partitions | ☐ |
| Feature status | `game_maintenance` | ☐ |
| Setting value | `new_game_enabled = '0'` | ☐ |
| multiplayer_games record | Active, correct ID | ☐ |

**Testing checklist**:

| Test | Status |
|------|--------|
| Game loads correctly as admin | ☐ |
| Ticks broadcast at correct interval | ☐ |
| Bets can be placed | ☐ |
| Settlements calculate correctly | ☐ |
| Winnings credited to wallet | ☐ |
| Mobile responsive | ☐ |
| Desktop layout correct | ☐ |

### 7.3 Phase 3: Production Preparation

**Duration**: 1 week

**Publish packages**:
```bash
# From gaming-service-pg-controller repo
npm version patch
npm publish

# From subwriter-pg-controller repo
npm version patch
npm publish
```

**Update dependencies** in all projects:
```json
{
  "@blazecode/gaming-service-pg-controller": "^X.Y.Z",
  "@blazecode/subwriter-pg-controller": "^X.Y.Z"
}
```

### 7.4 Phase 4: Deploy to Production

**Duration**: 1 day

**Deployment order** (critical):

| Order | Service | Command | Notes |
|-------|---------|---------|-------|
| 1 | Gaming Service | `npm run deploy:production` | Runs migrations |
| 2 | Server | `npm run deploy:production` | Runs feature status migration |
| 3 | Client | `npm run deploy:production` | Game accessible to admins |
| 4 | Admin | `npm run deploy:production` | Status dashboard available |

### 7.5 Phase 5: Slow Release

The slow release process gradually expands access to ensure stability.

#### 7.5.1 Admin-Only Testing (Day 1)

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `0` |
| Feature Status | `game_maintenance` |
| Access | Admins only (via direct URL) |

**Actions**:
- Test all game functionality in production
- Verify metrics and logging
- Check for any production-specific issues

#### 7.5.2 Whitelist/Beta Testing (Days 2-7)

**Change feature status**:
```
PUT /admin/waitlist_feature/new_game_room_1
{
  "status": "restricted_access",
  "notes": "Beta testing phase"
}
```

**Enable game setting**:
- Set `new_game_enabled = 1` in Gaming Service Settings

**Grant access to beta users**:
```
PUT /admin/waitlist_feature/new_game_room_1/change_status/{user_id}
```

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `1` |
| Feature Status | `restricted_access` |
| Access | Admins + whitelisted users |

#### 7.5.3 Waitlist Phase (Days 8-14) – Optional

Use this phase to build hype before public release.

| Setting | Value |
|---------|-------|
| Feature Status | `game_maintenance` |
| Waitlist | Open (users can sign up) |
| Game | Not playable |

**Gradually approve users**:
```
PUT /admin/waitlist_feature/new_game_room_1/bulk_grant_access
{
  "number_of_users": 100
}
```

#### 7.5.4 Global Release

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `1` |
| Feature Status | `globally_available` |
| Frontend restriction | Remove `isAdmin: true` |

**Post-release actions**:
- Add to home page carousel
- Add to game categories
- Send user notifications
- Publish marketing materials

---

## 8. Release Checklist

### 8.1 Pre-Deploy Checklist

#### Gaming Service

| Item | Status |
|------|--------|
| Engine class implemented | ☐ |
| Config file complete | ☐ |
| Games repository implemented | ☐ |
| Bets repository implemented | ☐ |
| Outcomes service implemented | ☐ |
| Validator service implemented | ☐ |
| Marshalling service implemented | ☐ |
| RNG function implemented | ☐ |
| Game runner worker created | ☐ |
| Migration created (games, bets, enums) | ☐ |
| Seed created (multiplayer_games, settings) | ☐ |
| Tests written and passing | ☐ |
| Engine registered in factory | ☐ |
| npm script added | ☐ |
| Package published | ☐ |

#### Server

| Item | Status |
|------|--------|
| Feature status migration created | ☐ |
| Constants updated | ☐ |
| Package published | ☐ |

#### Client

| Item | Status |
|------|--------|
| Game component created | ☐ |
| Redux store configured | ☐ |
| Socket handlers implemented | ☐ |
| Route added (admin-only) | ☐ |
| Navigation updated | ☐ |
| Game config added | ☐ |
| Original games constant added | ☐ |
| Assets uploaded to CDN | ☐ |

#### Admin

| Item | Status |
|------|--------|
| Game status config added | ☐ |
| Bet search implemented | ☐ |

### 8.2 Post-Deploy Checklist (Staging)

| Item | Status |
|------|--------|
| Tables created correctly | ☐ |
| Partitions verified (24 months) | ☐ |
| Feature status = `game_maintenance` | ☐ |
| Setting = `0` (disabled) | ☐ |
| Game loads for admin | ☐ |
| Ticks working | ☐ |
| Bets working | ☐ |
| Settlements working | ☐ |
| Sockets updating | ☐ |

### 8.3 Post-Deploy Checklist (Production)

| Item | Status |
|------|--------|
| Migrations successful | ☐ |
| Service health verified | ☐ |
| Admin testing complete | ☐ |
| Metrics collecting | ☐ |
| Logs clean | ☐ |
| Ready for whitelist | ☐ |

### 8.4 Post-Release Checklist

| Item | Status |
|------|--------|
| `isAdmin: true` removed from route | ☐ |
| `isAdmin: true` removed from navigation | ☐ |
| Feature status = `globally_available` | ☐ |
| Setting = `1` (enabled) | ☐ |
| Added to home page | ☐ |
| Added to categories | ☐ |
| User communication sent | ☐ |

---

## 9. Troubleshooting

### 9.1 Game doesn't appear in frontend

| Symptom | Cause | Solution |
|---------|-------|----------|
| 404 on game route | Route not registered | Add to CasinoPage.js Switch |
| Game shows but redirects | Feature flag blocking | Check feature_status table |
| Only works for some users | Admin restriction active | Remove `isAdmin: true` check |
| Blank screen | Asset loading failed | Check CDN paths in config |

### 9.2 Bets fail

| Symptom | Cause | Solution |
|---------|-------|----------|
| "Game not enabled" error | Setting disabled | Set `new_game_enabled = 1` |
| "No access" error | Feature status blocking | Check waitlist feature status |
| Bet not appearing | Socket not connected | Check socket handler registration |
| Insufficient funds | Wallet issue | Verify user balance |

### 9.3 Ticks not working

| Symptom | Cause | Solution |
|---------|-------|----------|
| Game stuck on waiting | Runner not started | Start game runner worker |
| Ticks not reaching client | Socket room issue | Verify roomId in config |
| Database errors | Missing tables | Run migrations |
| No games created | Missing multiplayer_games record | Run seed |

### 9.4 Settlement not processing

| Symptom | Cause | Solution |
|---------|-------|----------|
| Bets stay pending | Settlement worker stopped | Restart settlement worker |
| Wrong payouts | Calculation error | Review outcomes service |
| Wallet not credited | Transaction failed | Check transaction logs |

---

## 10. Reference: Lotto Beast Implementation

### 10.1 File Locations

| Component | Path |
|-----------|------|
| Engine | `gaming-service-betbr/packages/games/engines/lotto-beast-engine/` |
| RNG | `gaming-service-betbr/packages/math/lotto-beast/lotto-beast-rng.js` |
| DB Migration | `@blazecode/gaming-service-pg-controller/src/migrations/20250828120000-lotto-beast-game.js` |
| DB Seed | `@blazecode/gaming-service-pg-controller/src/seeds/20250828120000-lotto-beast-game.js` |
| Feature Status | `@blazecode/subwriter-pg-controller/src/seeds/20251215191236-add-lotto-beast-feature-status.js` |
| Frontend | `client-betbr/src/casino/originals/lotto-beast/` |
| Socket Handler | `client-betbr/src/app/networking/socketio-blaze-originals.js` |
| Admin Config | `admin-betbr/src/casino/game-status/tab-games-status/const.js` |

### 10.2 Timing Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `preRoundMs` | 15500 | 15.5 seconds betting window |
| `rollingMs` | 12000 | 12 seconds number reveal |
| `postRoundMs` | 5000 | 5 seconds results display |
| `tickMs` | 1000 | 1 second update frequency |
| `revealIntervalMs` | 2000 | 2 seconds between each number |

### 10.3 Multipliers

| Bet Type | Multiplier | Description |
|----------|------------|-------------|
| `full_number` | 9200x | 4-digit exact match (0000-9999) |
| `last_3` | 920x | Last 3 digits match |
| `last_2` | 92x | Last 2 digits match |
| `animal` | 23x | Animal betting (consecutive numbers) |

### 10.4 Mode Factors

| Mode | Factor | Effective Multiplier (full_number) |
|------|--------|-----------------------------------|
| `just_1st_raffle` | 1.0 | 9200x |
| `all_5_raffles` | 0.201 | ~1849x |

---

## 11. Executive Summary (Non-Technical)

### 11.1 What This Document Covers

This guide explains how to release a new game on the Blaze platform. It covers everything from initial development through production deployment with a controlled "slow release" that gradually expands access.

### 11.2 Key Systems Involved

Four main systems work together:

1. **Gaming Service**: Runs the actual game logic (dice rolls, card deals, etc.)
2. **Server**: Controls who can access the game (feature flags, waitlists)
3. **Client**: The website/app players use to play
4. **Admin Panel**: Tools for staff to manage and monitor the game

### 11.3 Release Approach

Games are released gradually to minimize risk:

1. **Admin-Only** (Day 1): Only internal staff can play
2. **Beta Testing** (Days 2-7): Selected users test the game
3. **Waitlist** (Optional): Users sign up, access granted in waves
4. **Public Release**: Everyone can play

### 11.4 Why This Matters

- **Reduced Risk**: Issues found early affect fewer users
- **Better Quality**: Real feedback before wide release
- **Controlled Load**: Servers aren't overwhelmed on day one
- **Easy Rollback**: Problems can be fixed before they spread

### 11.5 Timeline

A typical game release takes 6-8 weeks:
- Development: 2-4 weeks
- QA/Testing: 1-2 weeks
- Production Prep: 1 week
- Slow Release: 1-2 weeks

---

*Document based on Lotto Beast implementation.*
*Last updated: January 2026*
