sequenceDiagram
    autonumber
    participant SB as 🖥️ Server-betbr
    participant SQS as 📨 AWS SQS FIFO<br/>(free-bets-grants.fifo)
    participant GS as 🎮 Gaming-service
    
    rect rgb(200, 250, 200)
        Note over SB,GS: GRANT FLOW (Happy Path)
        SB->>SQS: sendMessage({userId, gameId, rounds})
        Note right of SB: MessageGroupId = userId<br/>Ensures FIFO per user
        SB-->>SB: Return success to user<br/>"Free bets in transit"
        
        loop Worker polling (every 20s)
            SQS->>GS: receiveMessage()
        end
        
        GS->>GS: creditFreeBetsV2()
        GS->>SQS: deleteMessage() ✅
        Note right of GS: ACK - Message removed
    end
    
    rect rgb(255, 200, 200)
        Note over SB,GS: FAILURE SCENARIO
        SQS->>GS: receiveMessage()
        GS->>GS: creditFreeBetsV2() ❌ FAILS
        Note right of GS: No deleteMessage = No ACK
        Note over SQS: After 30s visibility timeout<br/>Message re-delivered
        SQS->>GS: receiveMessage() (retry)
        Note over SQS: After 5 failures → DLQ
    end
