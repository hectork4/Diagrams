# How to Release a New Game - RGS Architecture Guide

---

> **Info Panel**
> This document describes the complete process for adding and releasing a new game in Blaze's RGS (Remote Gaming Service) architecture, from development to production with slow release.
>
> **Reference**: This tutorial is based on the **Lotto Beast** implementation as a case study.

---

## Table of Contents

| Section | Description |
|---------|-------------|
| [1. General Architecture](#1-general-architecture) | Overview of projects and data flow |
| [2. Gaming Service (RGS Backend)](#2-gaming-service-rgs-backend) | Game engine, migrations, RNG |
| [3. Server (OLTP Backend)](#3-server-oltp-backend) | Feature flags, waitlist |
| [4. Client (Frontend)](#4-client-frontend) | React components, sockets, Redux |
| [5. Admin Panel](#5-admin-panel) | Game management interface |
| [6. Step-by-Step Release Process](#6-step-by-step-release-process) | Deployment phases |
| [7. Release Checklist](#7-release-checklist) | Pre and post-deploy verification |

---

# 1. General Architecture

## 1.1 Projects Involved

| Project | Repository | Purpose |
|---------|------------|---------|
| **gaming-service-betbr** | RGS Backend | Game logic, ticks, bets, RNG |
| **server-betbr** | OLTP Backend | Feature flags, settings, waitlist |
| **client-betbr** | Frontend | Game UI, sockets, state |
| **admin-betbr** | Admin Panel | Management, configuration, release |

## 1.2 Migration Packages

| Package | Purpose |
|---------|---------|
| `@blazecode/gaming-service-pg-controller` | Gaming service migrations (game and bet tables) |
| `@blazecode/oltp-pg-controller` | Server migrations (general settings) |
| `@blazecode/subwriter-pg-controller` | Feature status and waitlist migrations |

## 1.3 Data Flow Diagram

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Client        │────▶│   Server         │────▶│  Gaming Service │
│   (React)       │◀────│   (Express)      │◀────│  (RGS)          │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                       │                        │
        ▼                       ▼                        ▼
   Socket.IO              Feature Flags            Game Ticks
   Updates                Waitlist                 Bets
                          Settings                 Settlements
```

---

# 2. Gaming Service (RGS Backend)

## 2.1 Game Structure

> **File Location**
> `/packages/games/engines/{game-name}-engine/`

**Directory Structure:**

| Path | Purpose |
|------|---------|
| `index.js` | Main engine class |
| `config.js` | Configuration (timing, limits, multipliers) |
| `workers/game-runner.js` | Main game loop (ticks) |
| `workers/settlement-worker.js` | Settlement process |
| `repos/{game}-games-repo.js` | Games repository |
| `repos/{game}-bets-repo.js` | Bets repository |
| `services/{game}-outcomes-service.js` | Determine winners/losers |
| `services/{game}-marshalling-service.js` | Format responses |
| `services/{game}-validator-service.js` | Specific validations |
| `services/{game}-admin-service.js` | Admin queries |
| `utils/calculations.js` | Multiplier calculations |
| `utils/payload-utils.js` | Payload helpers |
| `utils/tick-game-specific.js` | Game-specific tick fields |
| `tests/` | Game tests |

---

## 2.2 Create the Engine Class

> **File**: `/packages/games/engines/{game}-engine/index.js`

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

---

## 2.3 Game Configuration

> **File**: `/packages/games/engines/{game}-engine/config.js`

```javascript
module.exports = {
  gameType: 'new_game',
  gameName: 'NewGame',
  rooms: [1],  // Available rooms

  betParams: ['target', 'bet_type'],  // Bet parameters

  limits: {
    minBet: 0.1,
    maxBet: 100000,
    maxProfit: 5000000,  // Maximum payout per round
  },

  rules: {
    maxBetsPerRound: 50,
  },

  multipliers: {
    // Define game multipliers
  },

  timing: {
    preRoundMs: 15000,    // Time before rolling
    postRoundMs: 5000,    // Time after complete
    rollingMs: 10000,     // Rolling duration
    tickMs: 1000,         // Update frequency
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

**Configuration Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `gameType` | Internal game identifier | `'new_game'` |
| `gameName` | Display name | `'NewGame'` |
| `rooms` | Available room IDs | `[1]` |
| `limits.minBet` | Minimum bet amount | `0.1` |
| `limits.maxBet` | Maximum bet amount | `100000` |
| `limits.maxProfit` | Maximum payout per round | `5000000` |
| `timing.preRoundMs` | Betting window duration | `15000` |
| `timing.rollingMs` | Animation/reveal duration | `10000` |
| `timing.postRoundMs` | Results display duration | `5000` |
| `timing.tickMs` | Update broadcast frequency | `1000` |

---

## 2.4 Register the Engine

> **File**: `/packages/rgs-core/engine-factory.js`

```javascript
const NewGameEngine = require('../games/engines/new-game-engine/index.js');

const engines = {
  'new-game': new NewGameEngine({ db: dbPool }),
  // ... other engines
};
```

---

## 2.5 Create Database Migration

> **Warning Panel**
> Database migrations are critical. Always test in staging before production.

> **File**: `@blazecode/gaming-service-pg-controller/src/migrations/YYYYMMDDHHMMSS-new-game.js`

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
      id: {
        type: Sequelize.BIGINT,
        primaryKey: true,
      },
      status: {
        type: 'enum_new_game_games_status',
        allowNull: false,
        defaultValue: 'waiting',
      },
      // Game-specific fields (e.g., winning_number)
      result_field_1: Sequelize.INTEGER,
      result_field_2: Sequelize.INTEGER,

      multiplayer_game_id: {
        type: Sequelize.INTEGER,
        references: { model: 'multiplayer_games', key: 'id' },
      },
      server_roll_id: {
        type: Sequelize.UUID,
        references: { model: 'server_rolls', key: 'id' },
      },
      created_at: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.literal('CURRENT_TIMESTAMP'),
      },
      updated_at: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.literal('CURRENT_TIMESTAMP'),
      },
    });

    // 3. Create indexes
    await queryInterface.addIndex('new_game_games', ['status']);
    await queryInterface.addIndex('new_game_games', ['multiplayer_game_id']);
    await queryInterface.addIndex('new_game_games', ['server_roll_id']);

    // 4. Create bets table (partitioned by month)
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

    // 5. Create monthly partitions (2 years ahead)
    const partitions = [
      ['2025_01', '2025-01-01', '2025-02-01'],
      ['2025_02', '2025-02-01', '2025-03-01'],
      ['2025_03', '2025-03-01', '2025-04-01'],
      // ... continue for 24 months
    ];

    for (const [name, start, end] of partitions) {
      await queryInterface.sequelize.query(`
        CREATE TABLE new_game_bets_${name} PARTITION OF new_game_bets
        FOR VALUES FROM ('${start}') TO ('${end}');
      `);
    }

    // 6. Add to bet type enum
    await queryInterface.sequelize.query(`
      ALTER TYPE enum_bets_type ADD VALUE IF NOT EXISTS 'new_game';
    `);

    // 7. Add to transaction type enum
    await queryInterface.sequelize.query(`
      ALTER TYPE enum_transactions_type ADD VALUE IF NOT EXISTS 'new_game';
    `);
  },

  async down(queryInterface) {
    await queryInterface.dropTable('new_game_bets');
    await queryInterface.dropTable('new_game_games');
    await queryInterface.sequelize.query('DROP TYPE IF EXISTS enum_new_game_games_status;');
  },
};
```

**Migration Checklist:**

| Item | Status |
|------|--------|
| Create game status enum | Required |
| Create games table | Required |
| Create bets table (partitioned) | Required |
| Add indexes | Required |
| Add to enum_bets_type | Required |
| Add to enum_transactions_type | Required |

---

## 2.6 Create Seed for multiplayer_games

> **File**: `@blazecode/gaming-service-pg-controller/src/seeds/YYYYMMDDHHMMSS-new-game.js`

```javascript
'use strict';

module.exports = {
  async up(queryInterface) {
    // Register in multiplayer_games
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

    // Create initial setting (disabled)
    await queryInterface.sequelize.query(`
      INSERT INTO settings (key, value, created_at, updated_at)
      VALUES ('new_game_enabled', '0', NOW(), NOW())
      ON CONFLICT (key) DO NOTHING;
    `);
  },

  async down(queryInterface) {
    await queryInterface.sequelize.query(`
      DELETE FROM multiplayer_games WHERE game = 'new_game_room_1';
    `);
    await queryInterface.sequelize.query(`
      DELETE FROM settings WHERE key = 'new_game_enabled';
    `);
  },
};
```

---

## 2.7 Implement RNG (Provably Fair)

> **File**: `/packages/math/new-game/new-game-rng.js`

```javascript
const { generateCoreRngValues } = require('../core-rng');

/**
 * Converts a SHA-256 hash into the game result
 * @param {string} hash - 64-character hexadecimal hash
 * @returns {Object} - Game result
 */
const getNewGameRng = (hash) => {
  // generateCoreRngValues divides the hash into segments
  // and generates values in range [0, 2^52)
  const rngValues = generateCoreRngValues(hash);

  // Map to game-specific results
  // Example: 5 numbers between 0-9999
  const results = rngValues.map((value) => value % 10000);

  return {
    result_1: results[0],
    result_2: results[1],
    // ...
  };
};

module.exports = getNewGameRng;
```

> **Note Panel**
> The RNG must be deterministic based on the hash for Provably Fair verification.

---

## 2.8 Game Runner (Worker)

> **File**: `/packages/games/engines/new-game-engine/workers/game-runner.js`

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

## 2.9 Add Script to package.json

```json
{
  "scripts": {
    "prod:new-game-game-server": "node packages/games/engines/new-game-engine/workers/game-runner.js"
  }
}
```

---

# 3. Server (OLTP Backend)

## 3.1 Feature Status Migration

> **File**: `@blazecode/subwriter-pg-controller/src/seeds/YYYYMMDDHHMMSS-add-new-game-feature-status.js`

```javascript
'use strict';

module.exports = {
  async up(queryInterface) {
    await queryInterface.sequelize.query(`
      INSERT INTO feature_status (id, feature_name, status, created_at, updated_at)
      VALUES (
        DEFAULT,
        'new_game_room_1',
        'game_maintenance',
        NOW(),
        NOW()
      )
      ON CONFLICT (feature_name) DO NOTHING;
    `);
  },

  async down(queryInterface) {
    await queryInterface.sequelize.query(`
      DELETE FROM feature_status WHERE feature_name = 'new_game_room_1';
    `);
  },
};
```

---

## 3.2 Feature Status System

**Available States:**

| Status | Description | Game Access | Waitlist Access |
|--------|-------------|-------------|-----------------|
| `globally_available` | Everyone can play | YES | N/A |
| `restricted_access` | Only whitelisted users | YES (whitelist only) | NO |
| `waitlist_maintenance` | Disable waitlist signup | YES | NO |
| `game_maintenance` | Disable game play | NO | YES |
| `global_maintenance` | Everything disabled | NO | NO |

**State Transition Diagram:**

```
game_maintenance (Initial)
        │
        ▼
restricted_access (Beta Testing)
        │
        ▼
globally_available (Public Release)
```

---

## 3.3 Add to Constants

> **File**: `/packages/waitlist-feature/src/constants.js`

```javascript
const FEATURES = [
  // ... other games
  'new_game_room_1',
];
```

---

## 3.4 Update Package Version

After creating migrations, update dependencies:

```json
{
  "dependencies": {
    "@blazecode/gaming-service-pg-controller": "^X.Y.Z",
    "@blazecode/subwriter-pg-controller": "^X.Y.Z"
  }
}
```

---

# 4. Client (Frontend)

## 4.1 Component Structure

> **Location**: `/src/casino/originals/new-game/`

| Path | Purpose |
|------|---------|
| `NewGame.js` | Main component |
| `NewGame.module.css` | Styles |
| `constants.js` | Game constants |
| `logic/index.js` | Redux actions/reducers |
| `hooks/useGameHooks.js` | Asset loading |
| `hooks/use-animation.js` | Animations |
| `controller/` | Betting UI |
| `canvas/` | Rendering (Pixi.js) |
| `LiveBetTable/` | Bets table |
| `modal/` | Modals |
| `assets/` | Images, animations |

---

## 4.2 Register the Game

> **File**: `/src/app/constants/original-games.js`

```javascript
const ORIGINAL_GAMES = {
  // ... other games
  new_game: 'new-game',
};
```

---

## 4.3 Game Configuration

> **File**: `/src/casino/originals/core/config/games-config.js`

```javascript
export const GAME_CONFIGS = {
  'new-game': {
    displayName: 'New Game',
    cacheTime: {
      history: 60000,
      limits: 300000,
      lastGame: 30000,
    },
    roomId: 'new_game_room_1',
  },
};
```

---

## 4.4 Main Component

> **File**: `/src/casino/originals/new-game/NewGame.js`

```javascript
import React from 'react';
import { useInitGame, useLoadAssets } from './hooks/useGameHooks';
import LayoutGame from '../core/layout/LayoutGame';

const NewGame = ({ selectedWalletData }) => {
  const gameSlug = 'new-game';

  const { gameEnabled } = useInitGame({
    selectedWalletData,
    gameSlug,
  });

  const { isLoading, progress } = useLoadAssets({ gameSlug });

  if (isLoading) {
    return <LoadingScreen progress={progress} />;
  }

  return (
    <LayoutGame
      gameSlug={gameSlug}
      gameEnabled={gameEnabled}
      feature="new_game_enabled"
      featureRoom="new_game_room_1"
    >
      {/* Game content */}
    </LayoutGame>
  );
};

export default NewGame;
```

---

## 4.5 Register Route (Lazy Loading)

> **File**: `/src/casino/CasinoPage.js`

```javascript
import Loadable from 'react-loadable';

const NewGame = Loadable({
  loader: () => import('./originals/new-game/NewGame'),
  loading: PageLoadable,
  delay: 1000,
});

// In the Switch routes:
<Route path={`${base}/new-game`} component={NewGame} />

// For admin-only during development:
{isAdmin && <Route path={`${base}/new-game`} component={NewGame} />}
```

---

## 4.6 Add Socket Handlers

> **File**: `/src/app/networking/socketio-blaze-originals.js`

```javascript
import { SocketUpdate, SocketUpdateBetsResult } from './handlers/new-game';

this.handlers = {
  // ... other handlers
  'new_game.tick': new SocketUpdate(store),
  'new_game.user-bets-result': new SocketUpdateBetsResult(store),
};
```

---

## 4.7 Redux Store

> **File**: `/src/casino/originals/new-game/logic/index.js`

```javascript
const initialState = {
  status: 'waiting',
  total_eur_bet: 0,
  total_bets_placed: 0,
  bets: [],
  // Game-specific fields
};

const newGameReducer = createGameRedux({
  gameSlug: 'new-game',
  initialState,
  customReducers: {
    // Specific reducers
  },
});

export default newGameReducer;
```

---

## 4.8 Add to Navigation

> **File**: `/src/app/left-bar/constants.js`

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

---

# 5. Admin Panel

## 5.1 Add to Game Status

> **File**: `/src/casino/game-status/tab-games-status/const.js`

```javascript
export const GAMES_MAP = [
  // ... other games
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

---

## 5.2 Create Bet Search

> **File**: `/src/originals/search-new-game-bet.js`

```javascript
import React from 'react';
import SearchBetForm from './components/SearchBetForm';

const SearchNewGameBet = () => {
  return (
    <SearchBetForm
      gameType="new_game"
      endpoint="/admin/originals/new-game/bets"
      fields={['id', 'user_id', 'amount', 'target', 'multiplier', 'status']}
    />
  );
};

export default SearchNewGameBet;
```

---

## 5.3 Add to Admin Menu

Add links in the admin navigation for:
- Game bet search
- Game configuration
- Status monitoring

---

# 6. Step-by-Step Release Process

## Phase 1: Development (Staging)

### Gaming Service Tasks

| Task | Status |
|------|--------|
| Create game engine | TODO |
| Implement RNG | TODO |
| Create DB migrations | TODO |
| Create seeds | TODO |
| Implement game runner | TODO |
| Write tests | TODO |

### Server Tasks

| Task | Status |
|------|--------|
| Create feature status migration | TODO |
| Update feature constants | TODO |

### Client Tasks

| Task | Status |
|------|--------|
| Create game component | TODO |
| Implement UI and animations | TODO |
| Add socket handlers | TODO |
| Configure Redux store | TODO |
| Add route (admin-only) | TODO |

### Admin Tasks

| Task | Status |
|------|--------|
| Add to game status | TODO |
| Create bet search | TODO |

---

## Phase 2: QA in Staging

### Run Migrations

```bash
# Gaming Service
npm run db:migrate

# Server
npm run db:migrate
```

### Verification Checklist

| Item | Expected | Status |
|------|----------|--------|
| Tables created | `new_game_games`, `new_game_bets` | TODO |
| Bet partitions | 24 monthly partitions | TODO |
| Feature status | `game_maintenance` | TODO |
| Setting | `new_game_enabled` = '0' | TODO |

### Testing Checklist

| Test | Status |
|------|--------|
| Game works as admin | TODO |
| Game ticks correctly | TODO |
| Bets work | TODO |
| Settlements correct | TODO |
| Mobile tested | TODO |
| Desktop tested | TODO |

---

## Phase 3: Production Preparation

### Publish Packages

```bash
# From each pg-controller repo
npm version patch
npm publish
```

### Update Dependencies

```json
{
  "@blazecode/gaming-service-pg-controller": "^X.Y.Z",
  "@blazecode/subwriter-pg-controller": "^X.Y.Z"
}
```

---

## Phase 4: Deploy to Production

### Deployment Order

| Order | Service | Command |
|-------|---------|---------|
| 1 | Gaming Service | `npm run deploy:production` |
| 2 | Server | `npm run deploy:production` |
| 3 | Client | `npm run deploy:production` |
| 4 | Admin | `npm run deploy:production` |

---

## Phase 5: Slow Release

### 5.1 Admin-Only Testing (Day 1)

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `0` |
| Feature Status | `game_maintenance` |
| Access | Admins only via direct route |

---

### 5.2 Whitelist/Beta Testing (Days 2-7)

**Change Feature Status:**

```
PUT /admin/waitlist_feature/new_game_room_1
{
  "status": "restricted_access",
  "notes": "Beta testing phase"
}
```

**Grant Access to Beta Users:**

```
PUT /admin/waitlist_feature/new_game_room_1/change_status/{user_id}
```

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `1` |
| Feature Status | `restricted_access` |
| Access | Admins + whitelisted users |

---

### 5.3 Waitlist Phase (Days 8-14)

**Open Waitlist:**

| Setting | Value |
|---------|-------|
| Feature Status | `game_maintenance` |
| Waitlist | Open for signups |
| Game | Not playable (building hype) |

**Gradually Approve Users:**

```
PUT /admin/waitlist_feature/new_game_room_1/bulk_grant_access
{
  "number_of_users": 100
}
```

---

### 5.4 Global Release

| Setting | Value |
|---------|-------|
| `new_game_enabled` | `1` |
| Feature Status | `globally_available` |
| Frontend | Remove `isAdmin: true` flag |
| Navigation | Add to home page/categories |

---

# 7. Release Checklist

## Pre-Deploy Checklist

### Gaming Service

| Item | Status |
|------|--------|
| Engine implemented and tested | TODO |
| Migrations created (games, bets, enums) | TODO |
| Seeds created (multiplayer_games, settings) | TODO |
| RNG implemented | TODO |
| Game runner created | TODO |
| Tests passing | TODO |
| Package published with new version | TODO |

### Server

| Item | Status |
|------|--------|
| Feature_status migration created | TODO |
| Constants updated | TODO |
| Package published with new version | TODO |

### Client

| Item | Status |
|------|--------|
| Game component created | TODO |
| Socket handlers implemented | TODO |
| Redux store configured | TODO |
| Route added (admin-only) | TODO |
| Navigation updated | TODO |
| Assets uploaded to CDN | TODO |

### Admin

| Item | Status |
|------|--------|
| Game status configured | TODO |
| Bet search implemented | TODO |

---

## Post-Deploy (Staging) Checklist

| Item | Status |
|------|--------|
| Migrations executed successfully | TODO |
| Tables and partitions verified | TODO |
| Feature status in `game_maintenance` | TODO |
| Setting disabled | TODO |
| Game works correctly as admin | TODO |
| Bets work | TODO |
| Settlements correct | TODO |
| Sockets update correctly | TODO |

---

## Post-Deploy (Production) Checklist

| Item | Status |
|------|--------|
| Migrations executed successfully | TODO |
| Service health verified | TODO |
| Testing as admin complete | TODO |
| Whitelist phase started | TODO |
| Metrics being monitored | TODO |
| Ready for slow release | TODO |

---

## Post-Release Checklist

| Item | Status |
|------|--------|
| Admin-only restriction removed | TODO |
| Feature status set to `globally_available` | TODO |
| Setting enabled | TODO |
| Added to home page / categories | TODO |
| User communication sent | TODO |

---

# Appendix A: Useful Commands

| Command | Description |
|---------|-------------|
| `npm run db:migrate` | Run migrations locally |
| `npm run db:migrate:status` | Check migration status |
| `npm run db:migrate:undo` | Rollback last migration |
| `npm run dev:new-game-game-server` | Run game runner in development |
| `npm run logs:new-game` | View game logs |

---

# Appendix B: Troubleshooting

## Game doesn't appear in frontend

| Check | Solution |
|-------|----------|
| Route registered | Verify in CasinoPage.js |
| User is admin | Check if restriction applies |
| Feature flag | Verify configuration |

## Bets fail

| Check | Solution |
|-------|----------|
| Setting value | Verify `new_game_enabled` = 1 |
| Feature status | Verify allows access |
| Logs | Check gaming service logs |

## Ticks don't work

| Check | Solution |
|-------|----------|
| Game runner | Verify it's running |
| Database | Verify connection |
| multiplayer_games | Verify record exists |

## Settlement doesn't process

| Check | Solution |
|-------|----------|
| Settlement worker | Verify it's running |
| Calculations | Check for errors in multipliers |
| Logs | Review settlement service logs |

---

# Appendix C: Lotto Beast Reference

## File Locations

| Component | Path |
|-----------|------|
| Engine | `gaming-service-betbr/packages/games/engines/lotto-beast-engine/` |
| RNG | `gaming-service-betbr/packages/math/lotto-beast/lotto-beast-rng.js` |
| DB Migration | `@blazecode/gaming-service-pg-controller/src/migrations/20250828120000-lotto-beast-game.js` |
| DB Seed | `@blazecode/gaming-service-pg-controller/src/seeds/20250828120000-lotto-beast-game.js` |
| Feature Status Seed | `@blazecode/subwriter-pg-controller/src/seeds/20251215191236-add-lotto-beast-feature-status.js` |
| Frontend Component | `client-betbr/src/casino/originals/lotto-beast/` |
| Socket Handler | `client-betbr/src/app/networking/socketio-blaze-originals.js` |
| Admin Status Config | `admin-betbr/src/casino/game-status/tab-games-status/const.js` |

## Configuration Values (Lotto Beast)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `preRoundMs` | 15500 | 15.5 seconds for betting |
| `rollingMs` | 12000 | 12 seconds for number reveal |
| `postRoundMs` | 5000 | 5 seconds showing results |
| `tickMs` | 1000 | Updates every 1 second |
| `revealIntervalMs` | 2000 | Reveal 1 number every 2 seconds |
| `minBet` | 0.1 | Minimum bet amount |
| `maxProfit` | 5000000 | Maximum payout per round |
| `maxBetsPerRound` | 50 | Bets limit per user per round |

## Multipliers (Lotto Beast)

| Bet Type | Base Multiplier | Description |
|----------|-----------------|-------------|
| `full_number` | 9200x | 4-digit exact match |
| `last_3` | 920x | 3-digit match |
| `last_2` | 92x | 2-digit match |
| `animal` | 23x | Animal betting |

## Mode Factors

| Mode | Factor | Description |
|------|--------|-------------|
| `just_1st_raffle` | 1.0 | 100% of base multiplier |
| `all_5_raffles` | 0.201 | 20.1% of base multiplier |

---

*Document created based on Lotto Beast implementation.*
*Last update: January 2026*
