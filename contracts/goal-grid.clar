;; goal-grid.clar
;; GoalGrid Progress Tracker Contract

;; This contract enables users to create and track personal goals with nested milestones,
;; dependencies, and completion criteria. It maintains an immutable history of progress updates
;; and provides social accountability features with configurable privacy controls.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-GOAL-NOT-FOUND (err u101))
(define-constant ERR-MILESTONE-NOT-FOUND (err u102))
(define-constant ERR-GOAL-ALREADY-EXISTS (err u103))
(define-constant ERR-MILESTONE-ALREADY-EXISTS (err u104))
(define-constant ERR-INVALID-PERCENTAGE (err u105))
(define-constant ERR-PARENT-NOT-FOUND (err u106))
(define-constant ERR-INVALID-SUPPORTER (err u107))
(define-constant ERR-DEPENDENCY-NOT-FOUND (err u108))
(define-constant ERR-INVALID-PRIVACY-SETTING (err u109))

;; Privacy settings
(define-constant PRIVACY-PRIVATE u1)  ;; Only the owner can view
(define-constant PRIVACY-SUPPORTERS u2)  ;; Owner and designated supporters can view
(define-constant PRIVACY-PUBLIC u3)  ;; Anyone can view

;; Data structures

;; Map to store goal metadata
(define-map goals
  { owner: principal, goal-id: (string-ascii 32) }
  {
    title: (string-ascii 100),
    description: (string-utf8 500),
    target-date: (optional uint),
    created-at: uint,
    privacy: uint,
    completion-percentage: uint
  }
)

;; Map to store milestones for each goal
(define-map milestones
  { owner: principal, goal-id: (string-ascii 32), milestone-id: (string-ascii 32) }
  {
    title: (string-ascii 100),
    description: (string-utf8 500),
    target-date: (optional uint),
    parent-milestone: (optional (string-ascii 32)),
    completion-percentage: uint,
    verification-criteria: (string-utf8 300)
  }
)

;; Map to track dependencies between milestones
(define-map milestone-dependencies
  { owner: principal, goal-id: (string-ascii 32), milestone-id: (string-ascii 32), dependency-id: (string-ascii 32) }
  { is-dependency: bool }
)

;; Map to store designated supporters for each goal
(define-map goal-supporters
  { owner: principal, goal-id: (string-ascii 32), supporter: principal }
  { can-view: bool, can-verify: bool }
)

;; Map to store progress history (immutable record of updates)
(define-map progress-history
  { owner: principal, goal-id: (string-ascii 32), timestamp: uint }
  {
    milestone-id: (optional (string-ascii 32)),
    old-percentage: uint,
    new-percentage: uint,
    notes: (string-utf8 300)
  }
)

;; Helper to keep track of progress history entries
(define-map progress-history-index
  { owner: principal, goal-id: (string-ascii 32) }
  { entries: (list 100 uint) }  ;; List of timestamps for lookups
)

;; List of goal IDs per user for easy retrieval
(define-map user-goals
  { owner: principal }
  { goal-ids: (list 100 (string-ascii 32)) }
)

;; List of milestone IDs per goal for easy retrieval
(define-map goal-milestones
  { owner: principal, goal-id: (string-ascii 32) }
  { milestone-ids: (list 100 (string-ascii 32)) }
)

;; Private functions

;; Helper to check if a user can access a goal
(define-private (can-access-goal (owner principal) (goal-id (string-ascii 32)) (viewer principal))
  (let (
    (goal-map-entry (map-get? goals { owner: owner, goal-id: goal-id }))
  )
    (and
      (is-some goal-map-entry)  ;; Goal exists
      (or
        (is-eq owner viewer)  ;; Owner can always access
        (let (
          (privacy (get privacy (unwrap! goal-map-entry false)))
        )
          (or
            (is-eq privacy PRIVACY-PUBLIC)  ;; Public goals are accessible to all
            (and
              (is-eq privacy PRIVACY-SUPPORTERS)  ;; For supporter-only privacy
              (is-some (map-get? goal-supporters { owner: owner, goal-id: goal-id, supporter: viewer }))
            )
          )
        )
      )
    )
  )
)

;; Helper to add a goal ID to a user's list
(define-private (add-goal-to-user-list (owner principal) (goal-id (string-ascii 32)))
  (let (
    (current-list (default-to { goal-ids: (list) } (map-get? user-goals { owner: owner })))
  )
    (map-set user-goals
      { owner: owner }
      { goal-ids: (unwrap! (as-max-len? (append (get goal-ids current-list) goal-id) u100) ERR-GOAL-ALREADY-EXISTS) }
    )
  )
)

;; Helper to add a milestone ID to a goal's list
(define-private (add-milestone-to-goal-list (owner principal) (goal-id (string-ascii 32)) (milestone-id (string-ascii 32)))
  (let (
    (current-list (default-to { milestone-ids: (list) } (map-get? goal-milestones { owner: owner, goal-id: goal-id })))
  )
    (map-set goal-milestones
      { owner: owner, goal-id: goal-id }
      { milestone-ids: (unwrap! (as-max-len? (append (get milestone-ids current-list) milestone-id) u100) ERR-MILESTONE-ALREADY-EXISTS) }
    )
  )
)

;; Helper to record progress history
(define-private (record-progress-history 
  (owner principal) 
  (goal-id (string-ascii 32)) 
  (milestone-id (optional (string-ascii 32))) 
  (old-percentage uint) 
  (new-percentage uint)
  (notes (string-utf8 300))
)
  (let (
    (timestamp (unwrap-panic (get-block-info? time u0)))
    (current-index (default-to { entries: (list) } (map-get? progress-history-index { owner: owner, goal-id: goal-id })))
    (updated-entries (unwrap! (as-max-len? (append (get entries current-index) timestamp) u100) (err u199)))
  )
    ;; Save the progress entry
    (map-set progress-history
      { owner: owner, goal-id: goal-id, timestamp: timestamp }
      { 
        milestone-id: milestone-id,
        old-percentage: old-percentage,
        new-percentage: new-percentage,
        notes: notes
      }
    )
    
    ;; Update the index
    (map-set progress-history-index
      { owner: owner, goal-id: goal-id }
      { entries: updated-entries }
    )
    
    (ok timestamp)
  )
)

;; Helper to calculate goal completion based on milestone percentages
(define-private (calculate-goal-completion (owner principal) (goal-id (string-ascii 32)))
  (let (
    (milestones-list (get milestone-ids (default-to { milestone-ids: (list) } 
                       (map-get? goal-milestones { owner: owner, goal-id: goal-id }))))
    (milestone-count (len milestones-list))
  )
    (if (is-eq milestone-count u0)
      u0  ;; No milestones, so 0% complete
      (let (
        (total-percentage (fold calculate-milestone-sum milestones-list u0))
      )
        (/ total-percentage milestone-count)  ;; Average percentage across all milestones
      )
    )
  )
)

;; Helper for fold to sum milestone percentages
(define-private (calculate-milestone-sum (milestone-id (string-ascii 32)) (sum uint))
  (let (
    (milestone (map-get? milestones { 
      owner: tx-sender, 
      goal-id: (var-get current-calculation-goal-id), 
      milestone-id: milestone-id 
    }))
  )
    (if (is-some milestone)
      (+ sum (get completion-percentage (unwrap-panic milestone)))
      sum
    )
  )
)

;; Variable to help with fold calculation context
(define-data-var current-calculation-goal-id (string-ascii 32) "")

;; Read-only functions

;; Get goal details
(define-read-only (get-goal (owner principal) (goal-id (string-ascii 32)))
  (let (
    (can-view (can-access-goal owner goal-id tx-sender))
    (goal-data (map-get? goals { owner: owner, goal-id: goal-id }))
  )
    (if (and can-view (is-some goal-data))
      (ok (unwrap-panic goal-data))
      ERR-GOAL-NOT-FOUND
    )
  )
)

;; Get milestone details
(define-read-only (get-milestone (owner principal) (goal-id (string-ascii 32)) (milestone-id (string-ascii 32)))
  (let (
    (can-view (can-access-goal owner goal-id tx-sender))
    (milestone-data (map-get? milestones { owner: owner, goal-id: goal-id, milestone-id: milestone-id }))
  )
    (if (and can-view (is-some milestone-data))
      (ok (unwrap-panic milestone-data))
      ERR-MILESTONE-NOT-FOUND
    )
  )
)

;; Get all goals for a user (only those the viewer has permission to see)
(define-read-only (get-user-goals (owner principal))
  (let (
    (goal-list (get goal-ids (default-to { goal-ids: (list) } (map-get? user-goals { owner: owner }))))
  )
    (filter can-see-goal goal-list)
  )
)

;; Helper for filtering visible goals
(define-private (can-see-goal (goal-id (string-ascii 32)))
  (can-access-goal tx-sender goal-id tx-sender)
)

;; Get milestones for a goal
(define-read-only (get-goal-milestones (owner principal) (goal-id (string-ascii 32)))
  (let (
    (can-view (can-access-goal owner goal-id tx-sender))
    (milestone-list (get milestone-ids (default-to { milestone-ids: (list) } 
                      (map-get? goal-milestones { owner: owner, goal-id: goal-id }))))
  )
    (if can-view
      (ok milestone-list)
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Get progress history for a goal
(define-read-only (get-goal-progress-history (owner principal) (goal-id (string-ascii 32)))
  (let (
    (can-view (can-access-goal owner goal-id tx-sender))
    (history-entries (get entries (default-to { entries: (list) } 
                       (map-get? progress-history-index { owner: owner, goal-id: goal-id }))))
  )
    (if can-view
      (ok history-entries)
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Public functions

;; Create a new goal
(define-public (create-goal 
  (goal-id (string-ascii 32)) 
  (title (string-ascii 100)) 
  (description (string-utf8 500))
  (target-date (optional uint))
  (privacy uint)
)
  (begin
    ;; Check if the goal already exists
    (asserts! (is-none (map-get? goals { owner: tx-sender, goal-id: goal-id })) ERR-GOAL-ALREADY-EXISTS)
    
    ;; Validate privacy setting
    (asserts! (or (is-eq privacy PRIVACY-PRIVATE) 
                 (is-eq privacy PRIVACY-SUPPORTERS) 
                 (is-eq privacy PRIVACY-PUBLIC))
             ERR-INVALID-PRIVACY-SETTING)
    
    ;; Create the goal
    (map-set goals
      { owner: tx-sender, goal-id: goal-id }
      {
        title: title,
        description: description,
        target-date: target-date,
        created-at: (unwrap-panic (get-block-info? time u0)),
        privacy: privacy,
        completion-percentage: u0
      }
    )
    
    ;; Add to user's goals list
    (try! (as-contract (add-goal-to-user-list tx-sender goal-id)))
    
    ;; Create empty milestone list for this goal
    (map-set goal-milestones
      { owner: tx-sender, goal-id: goal-id }
      { milestone-ids: (list) }
    )
    
    ;; Record initial progress history
    (try! (record-progress-history tx-sender goal-id none u0 u0 "Goal created"))
    
    (ok true)
  )
)

;; Add a milestone to a goal
(define-public (add-milestone
  (goal-id (string-ascii 32))
  (milestone-id (string-ascii 32))
  (title (string-ascii 100))
  (description (string-utf8 500))
  (target-date (optional uint))
  (parent-milestone (optional (string-ascii 32)))
  (verification-criteria (string-utf8 300))
)
  (begin
    ;; Check if the goal exists and user is authorized
    (asserts! (is-some (map-get? goals { owner: tx-sender, goal-id: goal-id })) ERR-GOAL-NOT-FOUND)
    
    ;; Check if milestone already exists
    (asserts! (is-none (map-get? milestones { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id })) 
              ERR-MILESTONE-ALREADY-EXISTS)
    
    ;; If parent milestone is specified, ensure it exists
    (if (is-some parent-milestone)
      (asserts! (is-some (map-get? milestones 
                           { owner: tx-sender, 
                             goal-id: goal-id, 
                             milestone-id: (unwrap-panic parent-milestone) })) 
                ERR-PARENT-NOT-FOUND)
      true
    )
    
    ;; Create the milestone
    (map-set milestones
      { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id }
      {
        title: title,
        description: description,
        target-date: target-date,
        parent-milestone: parent-milestone,
        completion-percentage: u0,
        verification-criteria: verification-criteria
      }
    )
    
    ;; Add to goal's milestone list
    (try! (as-contract (add-milestone-to-goal-list tx-sender goal-id milestone-id)))
    
    ;; Record in progress history
    (try! (record-progress-history 
            tx-sender 
            goal-id 
            (some milestone-id) 
            u0 
            u0 
            "Milestone added"))
    
    (ok true)
  )
)

;; Add dependency between milestones
(define-public (add-milestone-dependency
  (goal-id (string-ascii 32))
  (milestone-id (string-ascii 32))
  (dependency-id (string-ascii 32))
)
  (begin
    ;; Check if user owns the goal
    (asserts! (is-some (map-get? goals { owner: tx-sender, goal-id: goal-id })) ERR-GOAL-NOT-FOUND)
    
    ;; Check if both milestones exist
    (asserts! (is-some (map-get? milestones { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id }))
              ERR-MILESTONE-NOT-FOUND)
    
    (asserts! (is-some (map-get? milestones { owner: tx-sender, goal-id: goal-id, milestone-id: dependency-id }))
              ERR-DEPENDENCY-NOT-FOUND)
    
    ;; Create the dependency
    (map-set milestone-dependencies
      { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id, dependency-id: dependency-id }
      { is-dependency: true }
    )
    
    (ok true)
  )
)

;; Update milestone progress
(define-public (update-milestone-progress
  (goal-id (string-ascii 32))
  (milestone-id (string-ascii 32))
  (new-percentage uint)
  (notes (string-utf8 300))
)
  (begin
    ;; Check if user owns the goal
    (asserts! (is-some (map-get? goals { owner: tx-sender, goal-id: goal-id })) ERR-GOAL-NOT-FOUND)
    
    ;; Check if milestone exists
    (let (
      (milestone (map-get? milestones { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id }))
    )
      (asserts! (is-some milestone) ERR-MILESTONE-NOT-FOUND)
      
      ;; Validate percentage (0-100)
      (asserts! (<= new-percentage u100) ERR-INVALID-PERCENTAGE)
      
      ;; Get current percentage for history
      (let (
        (old-percentage (get completion-percentage (unwrap-panic milestone)))
      )
        ;; Update milestone progress
        (map-set milestones
          { owner: tx-sender, goal-id: goal-id, milestone-id: milestone-id }
          (merge (unwrap-panic milestone) { completion-percentage: new-percentage })
        )
        
        ;; Record in progress history
        (try! (record-progress-history 
                tx-sender 
                goal-id 
                (some milestone-id) 
                old-percentage 
                new-percentage 
                notes))
        
        ;; Update overall goal progress
        (var-set current-calculation-goal-id goal-id)
        (let (
          (new-goal-percentage (calculate-goal-completion tx-sender goal-id))
          (goal-data (unwrap-panic (map-get? goals { owner: tx-sender, goal-id: goal-id })))
          (goal-old-percentage (get completion-percentage goal-data))
        )
          ;; Update goal completion percentage
          (map-set goals
            { owner: tx-sender, goal-id: goal-id }
            (merge goal-data { completion-percentage: new-goal-percentage })
          )
          
          ;; Record goal progress in history if it changed
          (if (not (is-eq goal-old-percentage new-goal-percentage))
            (try! (record-progress-history 
                    tx-sender 
                    goal-id 
                    none
                    goal-old-percentage 
                    new-goal-percentage 
                    "Overall goal progress updated"))
            (ok true)
          )
        )
      )
    )
  )
)

;; Add a supporter to a goal
(define-public (add-goal-supporter
  (goal-id (string-ascii 32))
  (supporter principal)
  (can-view bool)
  (can-verify bool)
)
  (begin
    ;; Check if user owns the goal
    (asserts! (is-some (map-get? goals { owner: tx-sender, goal-id: goal-id })) ERR-GOAL-NOT-FOUND)
    
    ;; Can't add yourself as a supporter
    (asserts! (not (is-eq tx-sender supporter)) ERR-INVALID-SUPPORTER)
    
    ;; Add supporter
    (map-set goal-supporters
      { owner: tx-sender, goal-id: goal-id, supporter: supporter }
      { can-view: can-view, can-verify: can-verify }
    )
    
    (ok true)
  )
)

;; Update goal privacy setting
(define-public (update-goal-privacy
  (goal-id (string-ascii 32))
  (privacy uint)
)
  (begin
    ;; Check if user owns the goal
    (let (
      (goal-data (map-get? goals { owner: tx-sender, goal-id: goal-id }))
    )
      (asserts! (is-some goal-data) ERR-GOAL-NOT-FOUND)
      
      ;; Validate privacy setting
      (asserts! (or (is-eq privacy PRIVACY-PRIVATE) 
                   (is-eq privacy PRIVACY-SUPPORTERS) 
                   (is-eq privacy PRIVACY-PUBLIC))
               ERR-INVALID-PRIVACY-SETTING)
      
      ;; Update privacy setting
      (map-set goals
        { owner: tx-sender, goal-id: goal-id }
        (merge (unwrap-panic goal-data) { privacy: privacy })
      )
      
      (ok true)
    )
  )
)

;; Verify milestone progress (for supporters with verification permission)
(define-public (verify-milestone-progress
  (owner principal)
  (goal-id (string-ascii 32))
  (milestone-id (string-ascii 32))
  (verification-notes (string-utf8 300))
)
  (begin
    ;; Check if goal exists
    (asserts! (is-some (map-get? goals { owner: owner, goal-id: goal-id })) ERR-GOAL-NOT-FOUND)
    
    ;; Check if milestone exists
    (asserts! (is-some (map-get? milestones { owner: owner, goal-id: goal-id, milestone-id: milestone-id }))
              ERR-MILESTONE-NOT-FOUND)
    
    ;; Check if sender is an authorized verifier
    (let (
      (supporter-data (map-get? goal-supporters { owner: owner, goal-id: goal-id, supporter: tx-sender }))
    )
      (asserts! (and (is-some supporter-data) (get can-verify (unwrap-panic supporter-data)))
                ERR-NOT-AUTHORIZED)
      
      ;; Record the verification in progress history
      (try! (record-progress-history 
              owner 
              goal-id 
              (some milestone-id) 
              u0  ;; Not changing percentage
              u0  ;; Not changing percentage
              (concat "Verified by " (concat (to-ascii tx-sender) (concat ": " verification-notes)))))
      
      (ok true)
    )
  )
)