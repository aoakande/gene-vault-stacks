;; GeneVault: Genetic Segments Management Contract
;; Handles the storage, access, and management of segmented genomic data

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-segment-exists (err u102))
(define-constant err-no-segment (err u103))
(define-constant err-invalid-segment (err u104))
(define-constant err-consent-required (err u105))

;; Data Maps and Variables
;; Track all genomic data segments with their metadata and access controls
(define-map genomic-segments
  { segment-id: (string-ascii 64) }
  {
    owner: principal,
    data-hash: (buff 32),       ;; Hash of the encrypted data stored off-chain (IPFS)
    segment-type: (string-ascii 20),  ;; e.g., "exome", "variant", "methylation"
    created-at: uint,
    access-level: uint,         ;; 1: public, 2: restricted, 3: private
    consent-expiry: uint        ;; Block height when consent expires
  }
)

;; Track which researchers have access to which segments
(define-map segment-access
  { segment-id: (string-ascii 64), researcher: principal }
  {
    granted-by: principal,
    granted-at: uint,
    expires-at: uint,
    purpose: (string-utf8 256)  ;; Research purpose description
  }
)

;; Maintain an index of segments owned by each provider
(define-map provider-segments
  { owner: principal }
  { segment-ids: (list 100 (string-ascii 64)) }
)

;; For research queries, track which segments were used
(define-map research-queries
  { query-id: (string-ascii 64) }
  {
    researcher: principal,
    segments-used: (list 100 (string-ascii 64)),
    query-type: (string-ascii 20),
    executed-at: uint,
    result-hash: (buff 32)
  }
)

;; Counters for governance and statistics
(define-data-var total-segments uint u0)
(define-data-var total-queries uint u0)

;; Private Functions
(define-private (is-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-segment-owner (segment-id (string-ascii 64)))
  (match (map-get? genomic-segments { segment-id: segment-id })
    segment (is-eq tx-sender (get owner segment))
    false
  )
)

(define-private (has-segment-access (segment-id (string-ascii 64)) (user principal))
  (or
    (is-segment-owner segment-id)
    (match (map-get? segment-access { segment-id: segment-id, researcher: user })
      access-info (< block-height (get expires-at access-info))
      false
    )
  )
)

(define-private (add-to-provider-segments (owner principal) (segment-id (string-ascii 64)))
  (let ((existing-entry (map-get? provider-segments { owner: owner })))
    (match existing-entry
      entry (map-set provider-segments 
                     { owner: owner } 
                     { segment-ids: (unwrap-panic (as-max-len? (append (get segment-ids entry) segment-id) u100)) })
      (map-set provider-segments 
               { owner: owner } 
               { segment-ids: (list segment-id) })
    )
    true
  )
)

;; Public Functions

;; Register a new genomic data segment
(define-public (register-segment 
                (segment-id (string-ascii 64)) 
                (data-hash (buff 32)) 
                (segment-type (string-ascii 20))
                (access-level uint)
                (consent-blocks uint))
  (let ((existing-segment (map-get? genomic-segments { segment-id: segment-id })))
    (asserts! (is-none existing-segment) (err err-segment-exists))
    (asserts! (and (>= access-level u1) (<= access-level u3)) (err err-invalid-segment))

    ;; Set the expiry block based on current block height plus the consent duration
    (let ((expiry-block (+ block-height consent-blocks)))
      ;; Register the segment
      (map-set genomic-segments 
               { segment-id: segment-id }
               { 
                 owner: tx-sender,
                 data-hash: data-hash,
                 segment-type: segment-type,
                 created-at: block-height,
                 access-level: access-level,
                 consent-expiry: expiry-block
               }
      )

      ;; Update the provider's segments list
      (add-to-provider-segments tx-sender segment-id)

      ;; Increment total segments counter
      (var-set total-segments (+ (var-get total-segments) u1))

      (ok segment-id)
    )
  )
)

;; Grant access to a researcher for a specific segment
(define-public (grant-access 
                (segment-id (string-ascii 64)) 
                (researcher principal)
                (duration uint)
                (purpose (string-utf8 256)))
  (let ((segment (map-get? genomic-segments { segment-id: segment-id })))
    ;; Verify the segment exists and sender is the owner
    (asserts! (is-some segment) (err err-no-segment))
    (asserts! (is-segment-owner segment-id) (err err-not-authorized))

    ;; Calculate expiry based on current block height
    (let ((expiry-block (+ block-height duration)))
      ;; Grant access
      (map-set segment-access
               { segment-id: segment-id, researcher: researcher }
               {
                 granted-by: tx-sender,
                 granted-at: block-height,
                 expires-at: expiry-block,
                 purpose: purpose
               }
      )

      (ok true)
    )
  )
)

;; Revoke previously granted access
(define-public (revoke-access (segment-id (string-ascii 64)) (researcher principal))
  (let ((access-info (map-get? segment-access { segment-id: segment-id, researcher: researcher })))
    ;; Verify access exists and sender is the segment owner
    (asserts! (is-some access-info) (err err-no-segment))
    (asserts! (is-segment-owner segment-id) (err err-not-authorized))

    ;; Revoke by setting expiry to current block
    (map-set segment-access
             { segment-id: segment-id, researcher: researcher }
             (merge (unwrap-panic access-info) { expires-at: block-height })
    )

    (ok true)
  )
)

;; Record a research query that uses specific segments
(define-public (record-research-query
                (query-id (string-ascii 64))
                (segments-used (list 100 (string-ascii 64)))
                (query-type (string-ascii 20))
                (result-hash (buff 32)))
  (let ((has-access (fold check-segment-access segments-used true)))
    ;; Verify access to all segments
    (asserts! has-access (err err-not-authorized))

    ;; Record the query
    (map-set research-queries
             { query-id: query-id }
             {
               researcher: tx-sender,
               segments-used: segments-used,
               query-type: query-type,
               executed-at: block-height,
               result-hash: result-hash
             }
    )

    ;; Increment queries counter
    (var-set total-queries (+ (var-get total-queries) u1))

    (ok query-id)
  )
)

;; Helper to check access to all segments in a list
(define-private (check-segment-access (segment-id (string-ascii 64)) (has-access bool))
  (if has-access
      (has-segment-access segment-id tx-sender)
      false)
)

;; Update segment metadata (only owner can do this)
(define-public (update-segment-access
                (segment-id (string-ascii 64))
                (new-access-level uint)
                (new-consent-duration uint))
  (let ((segment (map-get? genomic-segments { segment-id: segment-id })))
    ;; Verify the segment exists and sender is the owner
    (asserts! (is-some segment) (err err-no-segment))
    (asserts! (is-segment-owner segment-id) (err err-not-authorized))
    (asserts! (and (>= new-access-level u1) (<= new-access-level u3)) (err err-invalid-segment))

    ;; Calculate new expiry
    (let ((new-expiry (+ block-height new-consent-duration)))
      ;; Update the segment
      (map-set genomic-segments
               { segment-id: segment-id }
               (merge (unwrap-panic segment)
                     {
                       access-level: new-access-level,
                       consent-expiry: new-expiry
                     })
      )

      (ok true)
    )
  )
)

;; Read-only Functions

;; Get segment information (if public or has access)
(define-read-only (get-segment-info (segment-id (string-ascii 64)))
  (let ((segment (map-get? genomic-segments { segment-id: segment-id })))
    (match segment
      existing-segment (if (or (is-eq (get access-level existing-segment) u1)  ;; Public
                               (has-segment-access segment-id tx-sender))    ;; Has access
                           (ok existing-segment)
                           (err err-not-authorized))
      (err err-no-segment)
    )
  )
)

;; Check if a researcher has access to a segment
(define-read-only (check-access (segment-id (string-ascii 64)) (researcher principal))
  (ok (has-segment-access segment-id researcher))
)

;; Get all segments owned by a provider
(define-read-only (get-provider-segments (provider principal))
  (match (map-get? provider-segments { owner: provider })
    entry (ok (get segment-ids entry))
    (ok (list))
  )
)

;; Get details about a research query
(define-read-only (get-query-info (query-id (string-ascii 64)))
  (match (map-get? research-queries { query-id: query-id })
    query-info (ok query-info)
    (err err-no-segment)
  )
)

;; Get system statistics
(define-read-only (get-stats)
  (ok {
    total-segments: (var-get total-segments),
    total-queries: (var-get total-queries)
  })
)
