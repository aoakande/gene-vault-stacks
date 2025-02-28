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
  (match (map-get? provider-segments { owner: owner })
    existing-entry (map-set provider-segments 
                            { owner: owner } 
                            { segment-ids: (append (get segment-ids existing-entry) segment-id) })
    (map-set provider-segments 
             { owner: owner } 
             { segment-ids: (list segment-id) })
  )
)
