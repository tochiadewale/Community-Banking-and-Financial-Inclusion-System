;; Financial Cooperative Management Contract
;; Coordinates credit unions and community-owned financial institutions

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-COOP-NOT-FOUND (err u501))
(define-constant ERR-ALREADY-MEMBER (err u502))
(define-constant ERR-NOT-MEMBER (err u503))
(define-constant ERR-INSUFFICIENT-SHARES (err u504))
(define-constant ERR-INVALID-AMOUNT (err u505))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u506))
(define-constant ERR-VOTING-CLOSED (err u507))
(define-constant ERR-ALREADY-VOTED (err u508))
(define-constant ERR-INSUFFICIENT-RESERVES (err u509))

;; Data Variables
(define-data-var coop-counter uint u0)
(define-data-var proposal-counter uint u0)
(define-data-var min-share-price uint u100000) ;; 0.1 STX per share
(define-data-var voting-period uint u1008) ;; ~1 week in blocks

;; Data Maps
(define-map cooperatives
  { coop-id: uint }
  {
    name: (string-ascii 100),
    founder: principal,
    share-price: uint,
    total-shares: uint,
    total-members: uint,
    total-assets: uint,
    total-reserves: uint,
    dividend-rate: uint,
    governance-threshold: uint,
    active: bool,
    created-at: uint
  }
)

(define-map member-shares
  { coop-id: uint, member: principal }
  {
    shares-owned: uint,
    shares-value: uint,
    joined-at: uint,
    voting-power: uint,
    dividends-earned: uint,
    last-dividend: uint
  }
)

(define-map governance-proposals
  { proposal-id: uint }
  {
    coop-id: uint,
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    proposal-type: (string-ascii 50),
    amount-requested: uint,
    votes-for: uint,
    votes-against: uint,
    total-votes: uint,
    status: (string-ascii 20),
    created-at: uint,
    voting-ends: uint
  }
)

(define-map member-votes
  { proposal-id: uint, member: principal }
  {
    vote: bool,
    voting-power: uint,
    voted-at: uint
  }
)

(define-map profit-distributions
  { coop-id: uint, period: uint }
  {
    total-profit: uint,
    reserves-allocated: uint,
    dividends-distributed: uint,
    per-share-dividend: uint,
    distribution-date: uint
  }
)

;; Cooperative Management Functions
(define-public (create-cooperative (name (string-ascii 100)) (share-price uint) (governance-threshold uint))
  (let
    (
      (coop-id (+ (var-get coop-counter) u1))
      (current-block block-height)
    )
    (asserts! (>= share-price (var-get min-share-price)) ERR-INVALID-AMOUNT)
    (asserts! (> governance-threshold u0) ERR-INVALID-AMOUNT)
    (asserts! (<= governance-threshold u100) ERR-INVALID-AMOUNT)

    (map-set cooperatives
      { coop-id: coop-id }
      {
        name: name,
        founder: tx-sender,
        share-price: share-price,
        total-shares: u0,
        total-members: u0,
        total-assets: u0,
        total-reserves: u0,
        dividend-rate: u500, ;; 5% annual
        governance-threshold: governance-threshold,
        active: true,
        created-at: current-block
      }
    )

    (var-set coop-counter coop-id)
    (ok coop-id)
  )
)

(define-public (purchase-shares (coop-id uint) (num-shares uint))
  (let
    (
      (coop-data (unwrap! (map-get? cooperatives { coop-id: coop-id }) ERR-COOP-NOT-FOUND))
      (share-price (get share-price coop-data))
      (total-cost (* num-shares share-price))
      (current-member (map-get? member-shares { coop-id: coop-id, member: tx-sender }))
      (current-block block-height)
    )
    (asserts! (get active coop-data) ERR-NOT-AUTHORIZED)
    (asserts! (> num-shares u0) ERR-INVALID-AMOUNT)

    ;; Transfer payment to contract
    (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))

    ;; Update or create member record
    (match current-member
      existing-member
      (map-set member-shares
        { coop-id: coop-id, member: tx-sender }
        (merge existing-member {
          shares-owned: (+ (get shares-owned existing-member) num-shares),
          shares-value: (+ (get shares-value existing-member) total-cost),
          voting-power: (calculate-voting-power (+ (get shares-owned existing-member) num-shares))
        })
      )
      (begin
        (map-set member-shares
          { coop-id: coop-id, member: tx-sender }
          {
            shares-owned: num-shares,
            shares-value: total-cost,
            joined-at: current-block,
            voting-power: (calculate-voting-power num-shares),
            dividends-earned: u0,
            last-dividend: u0
          }
        )
        ;; Increment member count for new members
        (map-set cooperatives
          { coop-id: coop-id }
          (merge coop-data {
            total-members: (+ (get total-members coop-data) u1)
          })
        )
      )
    )

    ;; Update cooperative totals
    (map-set cooperatives
      { coop-id: coop-id }
      (merge coop-data {
        total-shares: (+ (get total-shares coop-data) num-shares),
        total-assets: (+ (get total-assets coop-data) total-cost)
      })
    )

    (ok num-shares)
  )
)

;; Governance Functions
(define-public (create-proposal (coop-id uint) (title (string-ascii 100)) (description (string-ascii 500)) (proposal-type (string-ascii 50)) (amount-requested uint))
  (let
    (
      (coop-data (unwrap! (map-get? cooperatives { coop-id: coop-id }) ERR-COOP-NOT-FOUND))
      (member-data (unwrap! (map-get? member-shares { coop-id: coop-id, member: tx-sender }) ERR-NOT-MEMBER))
      (proposal-id (+ (var-get proposal-counter) u1))
      (current-block block-height)
      (voting-ends (+ current-block (var-get voting-period)))
    )
    (asserts! (get active coop-data) ERR-NOT-AUTHORIZED)
    (asserts! (> (get shares-owned member-data) u0) ERR-INSUFFICIENT-SHARES)

    (map-set governance-proposals
      { proposal-id: proposal-id }
      {
        coop-id: coop-id,
        proposer: tx-sender,
        title: title,
        description: description,
        proposal-type: proposal-type,
        amount-requested: amount-requested,
        votes-for: u0,
        votes-against: u0,
        total-votes: u0,
        status: "active",
        created-at: current-block,
        voting-ends: voting-ends
      }
    )

    (var-set proposal-counter proposal-id)
    (ok proposal-id)
  )
)

(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let
    (
      (proposal-data (unwrap! (map-get? governance-proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
      (coop-id (get coop-id proposal-data))
      (member-data (unwrap! (map-get? member-shares { coop-id: coop-id, member: tx-sender }) ERR-NOT-MEMBER))
      (voting-power (get voting-power member-data))
      (current-block block-height)
    )
    (asserts! (is-eq (get status proposal-data) "active") ERR-VOTING-CLOSED)
    (asserts! (<= current-block (get voting-ends proposal-data)) ERR-VOTING-CLOSED)
    (asserts! (is-none (map-get? member-votes { proposal-id: proposal-id, member: tx-sender })) ERR-ALREADY-VOTED)
    (asserts! (> voting-power u0) ERR-INSUFFICIENT-SHARES)

    ;; Record vote
    (map-set member-votes
      { proposal-id: proposal-id, member: tx-sender }
      {
        vote: vote-for,
        voting-power: voting-power,
        voted-at: current-block
      }
    )

    ;; Update proposal vote counts
    (map-set governance-proposals
      { proposal-id: proposal-id }
      (merge proposal-data {
        votes-for: (if vote-for (+ (get votes-for proposal-data) voting-power) (get votes-for proposal-data)),
        votes-against: (if vote-for (get votes-against proposal-data) (+ (get votes-against proposal-data) voting-power)),
        total-votes: (+ (get total-votes proposal-data) voting-power)
      })
    )

    (ok true)
  )
)

(define-public (execute-proposal (proposal-id uint))
  (let
    (
      (proposal-data (unwrap! (map-get? governance-proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
      (coop-id (get coop-id proposal-data))
      (coop-data (unwrap! (map-get? cooperatives { coop-id: coop-id }) ERR-COOP-NOT-FOUND))
      (total-shares (get total-shares coop-data))
      (required-votes (/ (* total-shares (get governance-threshold coop-data)) u100))
      (current-block block-height)
    )
    (asserts! (is-eq (get status proposal-data) "active") ERR-VOTING-CLOSED)
    (asserts! (> current-block (get voting-ends proposal-data)) ERR-VOTING-CLOSED)
    (asserts! (>= (get votes-for proposal-data) required-votes) ERR-NOT-AUTHORIZED)
    (asserts! (> (get votes-for proposal-data) (get votes-against proposal-data)) ERR-NOT-AUTHORIZED)

    ;; Execute based on proposal type
    (let ((execution-result (execute-proposal-action proposal-data coop-data)))
      (map-set governance-proposals
        { proposal-id: proposal-id }
        (merge proposal-data {
          status: (if (is-ok execution-result) "executed" "failed")
        })
      )
      execution-result
    )
  )
)

;; Profit Distribution Functions
(define-public (distribute-profits (coop-id uint) (period uint) (total-profit uint) (reserve-percentage uint))
  (let
    (
      (coop-data (unwrap! (map-get? cooperatives { coop-id: coop-id }) ERR-COOP-NOT-FOUND))
      (total-shares (get total-shares coop-data))
      (reserves-allocated (/ (* total-profit reserve-percentage) u100))
      (dividends-available (- total-profit reserves-allocated))
      (per-share-dividend (if (> total-shares u0) (/ dividends-available total-shares) u0))
      (current-block block-height)
    )
    (asserts! (is-eq tx-sender (get founder coop-data)) ERR-NOT-AUTHORIZED)
    (asserts! (> total-profit u0) ERR-INVALID-AMOUNT)
    (asserts! (<= reserve-percentage u100) ERR-INVALID-AMOUNT)

    ;; Transfer profit to contract
    (try! (stx-transfer? total-profit tx-sender (as-contract tx-sender)))

    ;; Record distribution
    (map-set profit-distributions
      { coop-id: coop-id, period: period }
      {
        total-profit: total-profit,
        reserves-allocated: reserves-allocated,
        dividends-distributed: dividends-available,
        per-share-dividend: per-share-dividend,
        distribution-date: current-block
      }
    )

    ;; Update cooperative reserves
    (map-set cooperatives
      { coop-id: coop-id }
      (merge coop-data {
        total-reserves: (+ (get total-reserves coop-data) reserves-allocated),
        total-assets: (+ (get total-assets coop-data) total-profit)
      })
    )

    (ok per-share-dividend)
  )
)

(define-public (claim-dividends (coop-id uint) (period uint))
  (let
    (
      (member-data (unwrap! (map-get? member-shares { coop-id: coop-id, member: tx-sender }) ERR-NOT-MEMBER))
      (distribution-data (unwrap! (map-get? profit-distributions { coop-id: coop-id, period: period }) ERR-PROPOSAL-NOT-FOUND))
      (shares-owned (get shares-owned member-data))
      (per-share-dividend (get per-share-dividend distribution-data))
      (dividend-amount (* shares-owned per-share-dividend))
    )
    (asserts! (> dividend-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> (get last-dividend member-data) (get distribution-date distribution-data)) ERR-ALREADY-VOTED)

    ;; Transfer dividend to member
    (try! (stx-transfer? dividend-amount (as-contract tx-sender) tx-sender))

    ;; Update member dividend record
    (map-set member-shares
      { coop-id: coop-id, member: tx-sender }
      (merge member-data {
        dividends-earned: (+ (get dividends-earned member-data) dividend-amount),
        last-dividend: (get distribution-date distribution-data)
      })
    )

    (ok dividend-amount)
  )
)

;; Helper Functions
(define-private (calculate-voting-power (shares uint))
  ;; Simple linear voting power based on shares
  shares
)

(define-private (execute-proposal-action (proposal-data (tuple (coop-id uint) (proposer principal) (title (string-ascii 100)) (description (string-ascii 500)) (proposal-type (string-ascii 50)) (amount-requested uint) (votes-for uint) (votes-against uint) (total-votes uint) (status (string-ascii 20)) (created-at uint) (voting-ends uint))) (coop-data (tuple (name (string-ascii 100)) (founder principal) (share-price uint) (total-shares uint) (total-members uint) (total-assets uint) (total-reserves uint) (dividend-rate uint) (governance-threshold uint) (active bool) (created-at uint))))
  (let
    (
      (proposal-type (get proposal-type proposal-data))
      (amount (get amount-requested proposal-data))
      (coop-id (get coop-id proposal-data))
    )
    (if (is-eq proposal-type "fund-transfer")
      (execute-fund-transfer coop-id amount (get proposer proposal-data))
      (if (is-eq proposal-type "reserve-allocation")
        (execute-reserve-allocation coop-id amount)
        (ok true) ;; Default success for other proposal types
      )
    )
  )
)

(define-private (execute-fund-transfer (coop-id uint) (amount uint) (recipient principal))
  (let
    (
      (coop-data (unwrap-panic (map-get? cooperatives { coop-id: coop-id })))
    )
    (asserts! (>= (get total-reserves coop-data) amount) ERR-INSUFFICIENT-RESERVES)

    ;; Transfer funds
    (try! (stx-transfer? amount (as-contract tx-sender) recipient))

    ;; Update reserves
    (map-set cooperatives
      { coop-id: coop-id }
      (merge coop-data {
        total-reserves: (- (get total-reserves coop-data) amount)
      })
    )

    (ok true)
  )
)

(define-private (execute-reserve-allocation (coop-id uint) (amount uint))
  (let
    (
      (coop-data (unwrap-panic (map-get? cooperatives { coop-id: coop-id })))
    )
    ;; This would typically involve moving funds from general assets to reserves
    ;; For simplicity, we'll just update the reserve amount
    (map-set cooperatives
      { coop-id: coop-id }
      (merge coop-data {
        total-reserves: (+ (get total-reserves coop-data) amount)
      })
    )

    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-cooperative (coop-id uint))
  (map-get? cooperatives { coop-id: coop-id })
)

(define-read-only (get-member-shares (coop-id uint) (member principal))
  (map-get? member-shares { coop-id: coop-id, member: member })
)

(define-read-only (get-proposal (proposal-id uint))
  (map-get? governance-proposals { proposal-id: proposal-id })
)

(define-read-only (get-member-vote (proposal-id uint) (member principal))
  (map-get? member-votes { proposal-id: proposal-id, member: member })
)

(define-read-only (get-profit-distribution (coop-id uint) (period uint))
  (map-get? profit-distributions { coop-id: coop-id, period: period })
)

(define-read-only (get-counters)
  {
    cooperatives: (var-get coop-counter),
    proposals: (var-get proposal-counter)
  }
)

;; Admin Functions
(define-public (set-min-share-price (price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set min-share-price price)
    (ok true)
  )
)

(define-public (set-voting-period (blocks uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set voting-period blocks)
    (ok true)
  )
)
