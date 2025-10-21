;; A contract that allows periodic dividend distributions to token holders

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-cycle-not-found (err u101))
(define-constant err-already-claimed (err u102))
(define-constant err-no-balance (err u103))
(define-constant err-cycle-exists (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-transfer-failed (err u106))

;; Data Variables
(define-data-var current-cycle-id uint u0)
(define-data-var total-supply uint u1000000) ;; Example: 1M tokens

;; Data Maps
(define-map cycle-info
  { cycle-id: uint }
  {
    total-dividends: uint,
    snapshot-block: uint,
    total-supply-snapshot: uint,
    is-active: bool
  }
)

(define-map holder-snapshot
  { cycle-id: uint, holder: principal }
  { balance: uint }
)

(define-map claimed-status
  { cycle-id: uint, holder: principal }
  { claimed: bool }
)

;; Mock token balances (in production, integrate with actual SIP-010 token)
(define-map token-balances
  { holder: principal }
  { balance: uint }
)

;; Read-only functions

(define-read-only (get-cycle-info (cycle-id uint))
  (map-get? cycle-info { cycle-id: cycle-id })
)

(define-read-only (get-holder-snapshot (cycle-id uint) (holder principal))
  (map-get? holder-snapshot { cycle-id: cycle-id, holder: holder })
)

(define-read-only (has-claimed (cycle-id uint) (holder principal))
  (default-to 
    false 
    (get claimed (map-get? claimed-status { cycle-id: cycle-id, holder: holder }))
  )
)

(define-read-only (calculate-dividend-amount (cycle-id uint) (holder principal))
  (let
    (
      (cycle-data (unwrap! (get-cycle-info cycle-id) (err err-cycle-not-found)))
      (holder-data (unwrap! (get-holder-snapshot cycle-id holder) (err err-no-balance)))
      (holder-balance (get balance holder-data))
      (total-dividends (get total-dividends cycle-data))
      (cycle-total-supply (get total-supply-snapshot cycle-data))
    )
    (if (is-eq cycle-total-supply u0)
      (ok u0)
      (ok (/ (* holder-balance total-dividends) cycle-total-supply))
    )
  )
)

(define-read-only (get-token-balance (holder principal))
  (default-to 
    u0 
    (get balance (map-get? token-balances { holder: holder }))
  )
)

;; Private functions

(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

;; Public functions

(define-public (create-dividend-cycle)
  (let
    (
      (new-cycle-id (+ (var-get current-cycle-id) u1))
      (current-supply (var-get total-supply))
    )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-none (get-cycle-info new-cycle-id)) err-cycle-exists)
    
    ;; Create new cycle
    (map-set cycle-info
      { cycle-id: new-cycle-id }
      {
        total-dividends: u0,
        snapshot-block: u0,
        total-supply-snapshot: current-supply,
        is-active: true
      }
    )
    
    ;; Update current cycle ID
    (var-set current-cycle-id new-cycle-id)
    
    (ok new-cycle-id)
  )
)

;; Private function to validate cycle-id
(define-private (validate-cycle-id (cycle-id uint))
  (match (get-cycle-info cycle-id)
    cycle true
    false))

(define-public (record-snapshot (cycle-id uint) (holder principal) (balance uint))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (validate-cycle-id cycle-id) err-cycle-not-found)
    (asserts! (>= balance u0) err-invalid-amount)
    
    (let
      ((snapshot-data {
        cycle-id: cycle-id,
        holder: holder
      }))
      
      (map-set holder-snapshot
        snapshot-data
        { balance: balance }
      )
    )
    
    (ok true)
  )
)

;; Private function to update cycle dividends
(define-private (update-cycle-dividends (cycle-data (tuple (total-dividends uint) (snapshot-block uint) (total-supply-snapshot uint) (is-active bool))) (amount uint))
  (merge cycle-data { total-dividends: (+ (get total-dividends cycle-data) amount) }))

(define-public (fund-dividends (cycle-id uint) (amount uint))
  (let
    (
      (cycle-data (unwrap! (get-cycle-info cycle-id) err-cycle-not-found))
    )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (get is-active cycle-data) err-cycle-not-found)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update dividend amount
    (ok (map-set cycle-info
      { cycle-id: cycle-id }
      (update-cycle-dividends cycle-data amount)))
  )
)

(define-public (claim-dividend (cycle-id uint))
  (let
    (
      (cycle-data (unwrap! (get-cycle-info cycle-id) err-cycle-not-found))
      (holder-data (unwrap! (get-holder-snapshot cycle-id tx-sender) err-no-balance))
      (already-claimed (has-claimed cycle-id tx-sender))
      (dividend-amount (unwrap! (calculate-dividend-amount cycle-id tx-sender) err-invalid-amount))
    )
    (asserts! (not already-claimed) err-already-claimed)
    (asserts! (> dividend-amount u0) err-no-balance)
    (asserts! (get is-active cycle-data) err-cycle-not-found)
    
    ;; Transfer dividend to holder
    (try! (as-contract (stx-transfer? dividend-amount tx-sender (unwrap-panic (some tx-sender)))))
    
    ;; Mark as claimed
    (map-set claimed-status
      { cycle-id: cycle-id, holder: tx-sender }
      { claimed: true }
    )
    
    (ok dividend-amount)
  )
)

;; Private function to deactivate cycle
(define-private (deactivate-cycle (cycle-data (tuple (total-dividends uint) (snapshot-block uint) (total-supply-snapshot uint) (is-active bool))))
  (merge cycle-data { is-active: false }))

(define-public (close-cycle (cycle-id uint))
  (let
    (
      (cycle-data (unwrap! (get-cycle-info cycle-id) err-cycle-not-found))
    )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (get is-active cycle-data) err-cycle-not-found)
    
    (ok (map-set cycle-info
      { cycle-id: cycle-id }
      (deactivate-cycle cycle-data)))
  )
)

;; Helper function for testing - set token balance
(define-public (set-token-balance (holder principal) (balance uint))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (>= balance u0) err-invalid-amount)
    
    (map-set token-balances
      (tuple (holder holder))
      (tuple (balance balance)))
    
    (ok true)
  )
)