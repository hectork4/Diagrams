flowchart TD

  %% =========================
  %% PHASE 1: FREE BETS CREDIT
  %% =========================
  subgraph F1[PHASE 1: FREE BETS CREDIT]
    A1[Admin/Webhook POST /admin/free-bets/credit]
    A2[creditFreeRounds userId type rounds]

    A1 --> A2

    A2 --> B1[Create or update bonus_rounds +N]
    A2 --> B2[Insert bonus_round_transactions +N]

    B1 --> C1[Create free_winnings wallet if missing]
    B2 --> C1

    C1 --> D1[Emit WebSocket update]
  end

  %% =========================
  %% PHASE 2: BET PLACEMENT
  %% =========================
  subgraph F2[PHASE 2: BET PLACEMENT Legacy Crash]
    E1[User POST /crash free_bet true]
    E2[placeCrashBet]
    E3{wallet has free bet}
    E4[placeFreeBet crash]

    E1 --> E2 --> E3
    E3 -- yes --> E4

    E4 --> F1a[bonus_rounds rounds minus 1]
    F1a --> F1b[Insert bonus_round_transactions -1]
    F1b --> F1c[Insert free_bets created]
    F1c --> F1d[Insert bonus_round_bets link]
    F1d --> F1e[Return bet id and amount]

    E2 --> G1[Insert crash_bets free_bet true]
    G1 --> G2[Emit WebSocket update]
  end

  %% =========================
  %% PHASE 3: SETTLEMENT
  %% =========================
  subgraph F3[PHASE 3: SETTLEMENT]
    H1[Crash game ends]
    H2[CrashBetWon or CrashBetLost event]
    H3[Cron retryCrashPayouts]
    H4[Fetch placed bets]
    H5[Process each bet]
    H6{Is free bet}
    H7{Is win}

    H1 --> H2 --> H3 --> H4 --> H5 --> H6
    H6 -- yes --> H7

    H7 -- win --> H8[Payout free bet]
    H8 --> H9[Calculate win amount]
    H9 --> H10[Increase bonus wallet]
    H10 --> H11[Update free_bets win]
    H11 --> H12[Update bonus_round_bets]
    H12 --> H15[Emit WebSocket update]

    H7 -- loss --> H13[Close lost free bet]
    H13 --> H14[Update free_bets loss]
    H14 --> H15
  end

  %% =========================
  %% PHASE 4: TRANSFER
  %% =========================
  subgraph F4[PHASE 4: TRANSFER TO REAL WALLET]
    I1[Cron retryTransferFreeWinnings]
    I2[Find completed bonus rounds]
    I3[transferFreeWinnings]
    I4[Debit free_winnings wallet]
    I5[Insert outbound journal pending]
    I6[Mark bonus_rounds complete]
    I7[Attempt wallet transfer]
    I8[Call wallet service]
    I9{Transfer success}

    I1 --> I2 --> I3 --> I4 --> I5 --> I6 --> I7 --> I8 --> I9
    I9 -- yes --> I10[Mark journal complete]
    I10 --> I12[User sees real money]

    I9 -- no --> I11[Keep pending and retry]
    I11 --> I1
  end

  %% Flow connection
  F1 --> F2 --> F3 --> F4
