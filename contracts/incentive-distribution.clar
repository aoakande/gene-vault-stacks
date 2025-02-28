;; GeneVault: Incentive Distribution Contract
;; Handles payments, royalties, and value distribution for genomic data sharing
;; Implements Bitcoin anchoring for provenance and security

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-INSUFFICIENT-FUNDS (err u402)) 
(define-constant ERR-INVALID-PARAMETERS (err u403))
(define-constant ERR-ALREADY-PROCESSED (err u404))
(define-constant ERR-NOT-FOUND (err u405))

;; Constants
(define-constant contract-owner tx-sender)
(define-constant PROTOCOL-FEE-PERCENT u5) ;; 5% protocol fee
(define-constant MIN-PAYMENT u1000) ;; Minimum payment in microSTX
(define-constant BTC-CONFIRMATIONS u6) ;; Required BTC confirmations for anchoring

;; Data Maps
;; Track payments for data usage
(define-map payments
  { payment-id: (string-ascii 64) }
  {
    payer: principal,
    recipient: principal,
    amount: uint,
    segment-ids: (list 20 (string-ascii 64)),
    created-at: uint,
    processed: bool,
    btc-block-height: (optional uint),
    btc-block-hash: (optional (buff 32))
  }
)

;; Track revenue by data provider
(define-map provider-revenue
  { provider: principal }
  {
    total-earned: uint,
    pending-withdrawals: uint,
    last-withdrawal: uint,
    total-segments-used: uint
  }
)

;; Track research impact for citation-based incentives
(define-map research-impact
  { research-id: (string-ascii 64) }
  {
    researcher: principal,
    data-providers: (list 20 principal),
    citation-count: uint,
    impact-score: uint,
    last-updated: uint
  }
)

;; Store protocol stats and treasury
(define-data-var protocol-treasury uint u0)
(define-data-var total-payments uint u0)
(define-data-var total-payment-volume uint u0)
(define-data-var total-citations uint u0)

;; SIP-010 token trait for potential future token integration
(define-trait ft-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
    (get-decimals () (response uint uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
  )
)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (calculate-fee (amount uint))
  (/ (* amount PROTOCOL-FEE-PERCENT) u100)
)

(define-private (update-provider-revenue (provider principal) (payment-amount uint) (segments-count uint))
  (let ((existing-revenue (default-to 
                            { total-earned: u0, pending-withdrawals: u0, last-withdrawal: u0, total-segments-used: u0 }
                            (map-get? provider-revenue { provider: provider }))))
    (map-set provider-revenue
             { provider: provider }
             {
               total-earned: (+ (get total-earned existing-revenue) payment-amount),
               pending-withdrawals: (+ (get pending-withdrawals existing-revenue) payment-amount),
               last-withdrawal: (get last-withdrawal existing-revenue),
               total-segments-used: (+ (get total-segments-used existing-revenue) segments-count)
             }
    )
  )
)

;; Bitcoin anchoring function - integrates with Stacks blockchain for Bitcoin security
(define-private (anchor-to-bitcoin (payment-id (string-ascii 64)))
  (let ((block-info (get-block-info? burnchain-header-hash (- block-height u1))))
    (match (map-get? payments { payment-id: payment-id })
      payment (if (get processed payment)
                false
                (map-set payments
                        { payment-id: payment-id }
                        (merge payment {
                          btc-block-height: (some block-height),
                          btc-block-hash: block-info
                        })))
      false
    )
  )
)

;; Public functions

;; Process a payment for data usage
(define-public (process-payment 
                (payment-id (string-ascii 64))
                (recipient principal)
                (segment-ids (list 20 (string-ascii 64)))
                (amount uint))
  (let ((fee (calculate-fee amount))
        (provider-amount (- amount fee)))
    ;; Validate parameters
    (asserts! (>= amount MIN-PAYMENT) (err ERR-INVALID-PARAMETERS))
    (asserts! (> (len segment-ids) u0) (err ERR-INVALID-PARAMETERS))
    (asserts! (is-none (map-get? payments { payment-id: payment-id })) (err ERR-ALREADY-PROCESSED))
    ;; Process STX transfer
    (let ((transfer-result (stx-transfer? amount tx-sender (as-contract tx-sender))))
      (asserts! (is-ok transfer-result) (err ERR-INSUFFICIENT-FUNDS)))
    ;; Record payment details
    (map-set payments
             { payment-id: payment-id }
             {
               payer: tx-sender,
               recipient: recipient,
               amount: amount,
               segment-ids: segment-ids,
               created-at: block-height,
               processed: false,
               btc-block-height: none,
               btc-block-hash: none
             }
    )
    ;; Update provider revenue tracking
    (update-provider-revenue recipient provider-amount (len segment-ids))
    ;; Update protocol stats
    (var-set protocol-treasury (+ (var-get protocol-treasury) fee))
    (var-set total-payments (+ (var-get total-payments) u1))
    (var-set total-payment-volume (+ (var-get total-payment-volume) amount))
    ;; Anchor to Bitcoin for security
    (anchor-to-bitcoin payment-id)
    (ok payment-id)
  )
)

;; Complete payment by transferring STX to the recipient
(define-public (complete-payment (payment-id (string-ascii 64)))
  (let ((payment (unwrap! (map-get? payments { payment-id: payment-id }) (err ERR-NOT-FOUND))))
    ;; Validate state
    (asserts! (not (get processed payment)) (err ERR-ALREADY-PROCESSED))
    (asserts! (is-some (get btc-block-height payment)) (err ERR-INVALID-PARAMETERS))
    ;; Ensure Bitcoin confirmations
    (asserts! (>= (- block-height (unwrap! (get btc-block-height payment) (err ERR-INVALID-PARAMETERS))) 
                BTC-CONFIRMATIONS) 
              (err ERR-INVALID-PARAMETERS))
    ;; Calculate fee and provider amount
    (let ((fee (calculate-fee (get amount payment)))
          (provider-amount (- (get amount payment) fee)))
      ;; Transfer STX to recipient
      (let ((transfer-result (as-contract (stx-transfer? provider-amount tx-sender (get recipient payment)))))
        (asserts! (is-ok transfer-result) (err ERR-INSUFFICIENT-FUNDS)))
      ;; Mark payment as processed
      (map-set payments
               { payment-id: payment-id }
               (merge payment { processed: true }))
      (ok payment-id)
    )
  )
)

;; Register research citations to track impact
(define-public (register-citation
                (research-id (string-ascii 64))
                (data-providers (list 20 principal))
                (citation-count uint))
  (let ((existing-research (map-get? research-impact { research-id: research-id })))
    (asserts! (> (len data-providers) u0) (err ERR-INVALID-PARAMETERS))
    ;; Update or create research impact record
    (match existing-research
      prior-record (map-set research-impact
                           { research-id: research-id }
                           {
                             researcher: tx-sender,
                             data-providers: data-providers,
                             citation-count: (+ (get citation-count prior-record) citation-count),
                             impact-score: (+ (get impact-score prior-record) (* citation-count u10)),
                             last-updated: block-height
                           })
      ;; New record
      (map-set research-impact
               { research-id: research-id }
               {
                 researcher: tx-sender,
                 data-providers: data-providers,
                 citation-count: citation-count,
                 impact-score: (* citation-count u10),
                 last-updated: block-height
               })
    )
    ;; Update total citations
    (var-set total-citations (+ (var-get total-citations) citation-count))
    ;; Distribute impact bonuses to data providers (simplified implementation)
    (let ((impact-bonus (/ (* citation-count u1000) (len data-providers))))
      ;; Use fold instead of map to process each provider
      (fold distribute-impact-bonus data-providers true)
      (ok research-id)
    )
  )
)

;; Helper to distribute impact bonuses to providers
(define-private (distribute-impact-bonus (provider principal) (prior-result bool))
  (let ((existing-revenue (default-to 
                            { total-earned: u0, pending-withdrawals: u0, last-withdrawal: u0, total-segments-used: u0 }
                            (map-get? provider-revenue { provider: provider })))
        ;; Calculate bonus per provider - moved from calling function
        (bonus (/ (* (var-get total-citations) u1000) u1)))
    (map-set provider-revenue
             { provider: provider }
             (merge existing-revenue {
               total-earned: (+ (get total-earned existing-revenue) bonus),
               pending-withdrawals: (+ (get pending-withdrawals existing-revenue) bonus)
             })
    )
    true
  )
)

;; Provider withdraws earned STX
(define-public (withdraw-earnings)
  (let ((provider-info (default-to 
                          { total-earned: u0, pending-withdrawals: u0, last-withdrawal: u0, total-segments-used: u0 }
                          (map-get? provider-revenue { provider: tx-sender }))))
    (asserts! (> (get pending-withdrawals provider-info) u0) (err ERR-INSUFFICIENT-FUNDS))
    (let ((withdraw-amount (get pending-withdrawals provider-info)))
      ;; Transfer STX from contract to provider
      (let ((transfer-result (as-contract (stx-transfer? withdraw-amount tx-sender tx-sender))))
        (asserts! (is-ok transfer-result) (err ERR-INSUFFICIENT-FUNDS)))
      ;; Update provider record
      (map-set provider-revenue
               { provider: tx-sender }
               (merge provider-info {
                 pending-withdrawals: u0,
                 last-withdrawal: block-height
               })
      )
      (ok withdraw-amount)
    )
  )
)

;; Read-only functions

;; Get payment details
(define-read-only (get-payment (payment-id (string-ascii 64)))
  (map-get? payments { payment-id: payment-id })
)

;; Get provider revenue info
(define-read-only (get-provider-info (provider principal))
  (default-to 
    { total-earned: u0, pending-withdrawals: u0, last-withdrawal: u0, total-segments-used: u0 }
    (map-get? provider-revenue { provider: provider })
  )
)

;; Get research impact details
(define-read-only (get-research-impact (research-id (string-ascii 64)))
  (map-get? research-impact { research-id: research-id })
)

;; Get protocol stats
(define-read-only (get-protocol-stats)
  {
    treasury: (var-get protocol-treasury),
    total-payments: (var-get total-payments),
    payment-volume: (var-get total-payment-volume),
    total-citations: (var-get total-citations)
  }
)

;; Verify Bitcoin anchoring for a payment
(define-read-only (verify-bitcoin-anchoring (payment-id (string-ascii 64)))
  (match (map-get? payments { payment-id: payment-id })
    payment (if (and (is-some (get btc-block-height payment))
                     (is-some (get btc-block-hash payment)))
               (ok {
                 btc-block-height: (get btc-block-height payment),
                 btc-block-hash: (get btc-block-hash payment),
                 confirmations: (- block-height (default-to u0 (get btc-block-height payment)))
               })
               (err ERR-NOT-FOUND))
    (err ERR-NOT-FOUND)
  )
)
